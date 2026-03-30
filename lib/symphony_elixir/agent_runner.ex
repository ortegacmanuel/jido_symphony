defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in an isolated workspace using the configured agent adapter.
  """

  require Logger
  alias SymphonyElixir.{AgentAdapter, Config, Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_agent_turns(workspace, issue, agent_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
          maybe_merge_with_conflict_resolution(workspace, issue, agent_update_recipient, opts)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  # Pull latest master into the feature branch. If there are conflicts,
  # let the LLM agent resolve them in a dedicated turn.
  # When auto_merge is disabled (e.g. for GitHub PR-based workflows),
  # skip the merge pipeline entirely — the after_run hook handles pushing
  # the feature branch and creating a PR for human review.
  defp maybe_merge_with_conflict_resolution(workspace, issue, agent_update_recipient, opts) do
    if Config.auto_merge?() do
      do_merge_pipeline(workspace, issue, agent_update_recipient, opts)
    else
      Logger.info("Auto-merge disabled; skipping merge pipeline for #{issue_context(issue)}")
      :ok
    end
  end

  defp do_merge_pipeline(workspace, issue, agent_update_recipient, opts) do
    case Workspace.pull_main_into_branch(workspace) do
      :ok ->
        Logger.info("Clean merge of master into feature branch for #{issue_context(issue)}")
        commit_and_push_branch(workspace, issue)

        case Workspace.merge_feature_branch(workspace, issue) do
          :ok -> close_issue_after_merge(issue)
          _ -> :ok
        end

      {:conflict, files} ->
        Logger.info("Merge conflicts with master for #{issue_context(issue)}: #{inspect(files)}; running LLM conflict resolution")
        run_conflict_resolution_turn(workspace, issue, files, agent_update_recipient, opts)

      :skip ->
        Logger.debug("No feature branch to merge for #{issue_context(issue)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Merge/conflict-resolution failed for #{issue_context(issue)}: #{Exception.message(error)}; feature branch is still pushed as safety net")
      :ok
  end

  defp run_conflict_resolution_turn(workspace, issue, conflicted_files, agent_update_recipient, opts) do
    prompt = build_conflict_resolution_prompt(workspace, conflicted_files)

    with {:ok, adapter} <- resolve_adapter(),
         {:ok, session} <- adapter.start_session(workspace, opts) do
      try do
        adapter.run_turn(
          session,
          prompt,
          issue,
          on_message: agent_message_handler(agent_update_recipient, issue)
        )
      after
        adapter.stop_session(session)
      end
    end

    case Workspace.finalize_conflict_resolution(workspace) do
      :ok ->
        Logger.info("LLM resolved merge conflicts for #{issue_context(issue)}")
        commit_and_push_branch(workspace, issue)

        case Workspace.merge_feature_branch(workspace, issue) do
          :ok -> close_issue_after_merge(issue)
          _ -> :ok
        end

      {:error, reason} ->
        Logger.warning("Conflict resolution incomplete for #{issue_context(issue)}: #{inspect(reason)}; aborting merge")
        System.cmd("git", ["merge", "--abort"], cd: workspace, stderr_to_stdout: true)
        :ok
    end
  end

  defp build_conflict_resolution_prompt(workspace, conflicted_files) do
    file_previews =
      conflicted_files
      |> Enum.take(10)
      |> Enum.map(fn file ->
        path = Path.join(workspace, file)

        content =
          case File.read(path) do
            {:ok, data} -> String.slice(data, 0, 4_000)
            _ -> "(could not read)"
          end

        "### #{file}\n```\n#{content}\n```"
      end)
      |> Enum.join("\n\n")

    """
    ## Merge Conflict Resolution

    While merging the latest `master` into your feature branch, the following files have conflicts:

    #{Enum.map_join(conflicted_files, "\n", &"- `#{&1}`")}

    The files contain standard git conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
    Your job is to resolve ALL conflicts by editing each file to produce the correct merged result.

    **Guidelines:**
    - Keep functionality from BOTH sides where possible
    - Remove all conflict markers — no `<<<<<<<`, `=======`, or `>>>>>>>` should remain
    - Make sure the code compiles and is logically correct after resolution
    - Do NOT delete code from either side unless it's truly redundant
    - After editing all conflicted files, run `git add -A` to stage your resolutions

    #{file_previews}
    """
  end

  defp commit_and_push_branch(workspace, issue) do
    git = fn args -> System.cmd("git", args, cd: workspace, stderr_to_stdout: true) end

    # Stage and commit any merge-related changes
    case git.(["diff", "--quiet", "HEAD"]) do
      {_, 0} -> :ok
      _ ->
        git.(["add", "-A"])
        git.(["commit", "-m", "merge: integrate latest master for #{issue_context(issue)}"])
    end

    # Push the updated feature branch
    git.(["push", "origin", "HEAD", "--force-with-lease"])
    :ok
  rescue
    _ -> :ok
  end

  defp close_issue_after_merge(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    Logger.info("Closing issue after successful merge: #{issue_context(issue)}")

    case Tracker.update_issue_state(issue_id, "Done") do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Failed to close issue #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp close_issue_after_merge(_issue), do: :ok

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
      record_agent_event(issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp record_agent_event(%Issue{id: issue_id}, message) when is_binary(issue_id) do
    SymphonyElixir.AgentEventStore.record(issue_id, message)
  end

  defp record_agent_event(_issue, _message), do: :ok

  defp resolve_adapter do
    agent_kind = Config.agent_kind()
    AgentAdapter.adapter_for_kind(agent_kind)
  end

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, adapter} <- resolve_adapter(),
         {:ok, session} <- adapter.start_session(workspace, opts) do
      try do
        do_run_agent_turns(adapter, session, workspace, issue, agent_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        adapter.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(adapter, session, workspace, issue, agent_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           adapter.run_turn(
             session,
             prompt,
             issue,
             on_message: agent_message_handler(agent_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      if agent_signaled_completion?(workspace) do
        Logger.info("Agent signaled completion (pr-body.md exists) for #{issue_context(issue)} after turn #{turn_number}/#{max_turns}")
        :ok
      else
        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_agent_turns(
              adapter,
              session,
              workspace,
              refreshed_issue,
              agent_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp agent_signaled_completion?(workspace) do
    File.exists?(Path.join(workspace, ".symphony/pr-body.md"))
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
