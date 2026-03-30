defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")
    File.write!("/tmp/symphony-hook-debug.log", "hook=#{hook_name} workspace=#{workspace} id=#{issue_context.issue_identifier}\n", [:append])

    extra_env = [
      {"SYMPHONY_ISSUE_ID", issue_context.issue_identifier || ""},
      {"SYMPHONY_ISSUE_TITLE", issue_context[:issue_title] || ""}
    ]

    # Merge with system environment so hooks have PATH, GH_TOKEN, HOME, etc.
    env = System.get_env() |> Map.new() |> Map.merge(Map.new(extra_env)) |> Enum.to_list()

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true, env: env)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier, title: title}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: title
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_title: nil
    }
  end

  @doc """
  Pulls latest origin/master into the workspace's feature branch so the agent
  can resolve any merge conflicts while the session is still alive.

  Returns:
  - `:ok` — clean merge, no conflicts
  - `{:conflict, files}` — merge conflicts; conflict markers are in the working tree
  - `:skip` — workspace is on master/main or not a git repo
  """
  @spec pull_main_into_branch(Path.t()) :: :ok | {:conflict, [String.t()]} | :skip
  def pull_main_into_branch(workspace) when is_binary(workspace) do
    case detect_feature_branch(workspace) do
      {:ok, _branch} ->
        git = &git_cmd(workspace, &1)

        with {_, 0} <- git.(["fetch", "origin", "master"]) do
          case git.(["merge", "--no-edit", "origin/master"]) do
            {_, 0} ->
              :ok

            {_output, _} ->
              # Merge started but has conflicts — find the conflicted files
              {ls_output, _} = git.(["diff", "--name-only", "--diff-filter=U"])
              files = ls_output |> String.trim() |> String.split("\n", trim: true)

              if files == [] do
                # Merge failed for a non-conflict reason; abort
                git.(["merge", "--abort"])
                :skip
              else
                {:conflict, files}
              end
          end
        else
          _ -> :skip
        end

      :skip ->
        :skip
    end
  end

  def pull_main_into_branch(_workspace), do: :skip

  @doc """
  Finalizes a merge after the agent has resolved conflicts.
  Stages all changes and completes the merge commit.
  """
  @spec finalize_conflict_resolution(Path.t()) :: :ok | {:error, term()}
  def finalize_conflict_resolution(workspace) when is_binary(workspace) do
    git = &git_cmd(workspace, &1)

    with {_, 0} <- git.(["add", "-A"]) do
      # Check if there are still unresolved conflicts
      {remaining, _} = git.(["diff", "--name-only", "--diff-filter=U"])
      remaining_trimmed = String.trim(remaining)

      if remaining_trimmed == "" do
        case git.(["-c", "core.editor=true", "commit", "--no-edit"]) do
          {_, 0} -> :ok
          {output, _} -> {:error, {:commit_failed, String.slice(output, 0, 200)}}
        end
      else
        {:error, :unresolved_conflicts}
      end
    else
      {output, _} -> {:error, {:stage_failed, String.slice(to_string(output), 0, 200)}}
    end
  end

  @doc """
  Merges the current feature branch into master and pushes.

  Expects the feature branch to already include origin/master (via
  `pull_main_into_branch/1` + agent conflict resolution). This makes
  the merge to master a fast-forward in the common case.

  Retries up to 3 times on push race conditions. On failure, the
  feature branch is still pushed as a safety net.
  """
  @max_merge_retries 3

  @spec merge_feature_branch(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def merge_feature_branch(workspace, issue_or_identifier) when is_binary(workspace) do
    ctx = issue_context(issue_or_identifier)
    log_ctx = issue_log_context(ctx)

    case detect_feature_branch(workspace) do
      {:ok, branch} ->
        Logger.info("Merging feature branch branch=#{branch} #{log_ctx} workspace=#{workspace}")
        do_merge_with_retries(workspace, branch, log_ctx, 1)

      :skip ->
        Logger.debug("No feature branch to merge #{log_ctx} workspace=#{workspace}")
        :ok
    end
  end

  def merge_feature_branch(_workspace, _issue), do: :ok

  defp detect_feature_branch(workspace) do
    case git_cmd(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch_raw, 0} ->
        branch = String.trim(branch_raw)

        if branch in ["master", "main", "HEAD"] do
          :skip
        else
          {:ok, branch}
        end

      _ ->
        :skip
    end
  end

  defp do_merge_with_retries(workspace, branch, log_ctx, attempt) when attempt <= @max_merge_retries do
    case attempt_merge_and_push(workspace, branch) do
      :ok ->
        Logger.info("Feature branch merged to master branch=#{branch} #{log_ctx} attempt=#{attempt}")
        :ok

      {:error, :push_rejected} when attempt < @max_merge_retries ->
        Logger.warning("Push rejected (race), retrying merge branch=#{branch} #{log_ctx} attempt=#{attempt}")
        do_merge_with_retries(workspace, branch, log_ctx, attempt + 1)

      {:error, reason} ->
        Logger.warning("Merge failed branch=#{branch} #{log_ctx} attempt=#{attempt} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_merge_with_retries(_workspace, branch, log_ctx, _attempt) do
    Logger.warning("Merge retries exhausted branch=#{branch} #{log_ctx}")
    {:error, :merge_retries_exhausted}
  end

  defp attempt_merge_and_push(workspace, branch) do
    git = &git_cmd(workspace, &1)

    with {_, 0} <- git.(["fetch", "origin", "master"]),
         {_, 0} <- git.(["checkout", "master"]),
         {_, 0} <- git.(["reset", "--hard", "origin/master"]),
         :ok <- do_merge(workspace, branch),
         :ok <- ensure_target_repo_clean(workspace) do
      case git.(["push", "origin", "master"]) do
        {_, 0} ->
          git.(["checkout", branch])
          :ok

        {output, _} ->
          git.(["checkout", branch])

          if String.contains?(output, "rejected") or String.contains?(output, "non-fast-forward") do
            {:error, :push_rejected}
          else
            {:error, {:push_failed, String.slice(output, 0, 200)}}
          end
      end
    else
      {output, _status} ->
        git.(["checkout", branch])
        {:error, {:git_failed, String.slice(to_string(output), 0, 200)}}
    end
  end

  defp do_merge(workspace, branch) do
    git = &git_cmd(workspace, &1)

    # Try fast-forward first (expected path after pull_main_into_branch)
    case git.(["merge", "--ff-only", branch]) do
      {_, 0} ->
        :ok

      _ ->
        case git.(["merge", "--no-edit", branch]) do
          {_, 0} ->
            :ok

          {output, _} ->
            git.(["merge", "--abort"])
            {:error, {:merge_conflict, String.slice(output, 0, 200)}}
        end
    end
  end

  defp git_cmd(workspace, args) do
    System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  # When `receive.denyCurrentBranch=updateInstead` is set on the target repo,
  # pushes are rejected if the target has unstaged changes (e.g. .beads/issues.jsonl
  # modified by the orchestrator). This commits those changes so the push can proceed.
  defp ensure_target_repo_clean(workspace) do
    {url, 0} = git_cmd(workspace, ["remote", "get-url", "origin"])
    target = String.trim(url)

    if File.dir?(target) do
      case System.cmd("git", ["status", "--porcelain"], cd: target, stderr_to_stdout: true) do
        {output, 0} when byte_size(output) > 0 ->
          Logger.debug("Auto-committing dirty files in target repo #{target}")
          System.cmd("git", ["add", "-A"], cd: target, stderr_to_stdout: true)
          System.cmd("git", ["commit", "-m", "chore: auto-commit tracker state before merge"],
            cd: target, stderr_to_stdout: true)
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
