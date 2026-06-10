defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Provider-neutral runtime selection for the agent runner.

  Codex remains the default and reference runtime. When
  `agent_runtime.provider` is `claude_code`, role turns run through the
  first-party Claude Code shim instead. Both adapters expose the same logical
  session lifecycle (`start_session/2`, `run_turn/4`, `stop_session/1`) and emit
  the same normalized Symphony runtime events, so the orchestrator, status
  surfaces, and handoff logic are provider-agnostic.
  """

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.Config

  @type provider :: :codex | :claude_code

  @doc """
  Resolve the configured runtime adapter module.

  Defaults to the Codex adapter so existing Codex-backed workflows are
  unchanged.
  """
  @spec adapter() :: module()
  def adapter, do: adapter(provider())

  @spec adapter(provider()) :: module()
  def adapter(:claude_code), do: ClaudeAppServer
  def adapter(:codex), do: CodexAppServer

  @doc "Return the configured runtime provider atom."
  @spec provider() :: provider()
  def provider do
    case Config.settings!().agent_runtime.provider do
      "claude_code" -> :claude_code
      _ -> :codex
    end
  end

  @doc """
  Start a runtime session with the configured adapter.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts) do
    adapter().start_session(workspace, opts)
  end

  @doc """
  Run a turn with the configured adapter, threading any provider session id
  forward so continuation turns resume the same conversation.
  """
  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, {map(), map()}} | {:error, term()}
  def run_turn(session, prompt, issue, opts) do
    case adapter().run_turn(session, prompt, issue, opts) do
      {:ok, turn_result} ->
        {:ok, {advance_session(session, turn_result), turn_result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop the runtime session with the configured adapter."
  @spec stop_session(map()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)

  # Carry the provider session id forward for adapters (Claude Code) that run a
  # fresh process per turn and resume by session id. Codex keeps one long-lived
  # thread, so its session struct is returned unchanged.
  defp advance_session(session, %{session_id: session_id})
       when is_map_key(session, :claude_session_id) and is_binary(session_id) do
    %{session | claude_session_id: session_id}
  end

  defp advance_session(session, _turn_result), do: session
end
