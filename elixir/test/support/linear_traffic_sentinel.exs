defmodule SymphonyElixir.TestSupport.LinearTrafficSentinel do
  @moduledoc """
  Suite-wide proof that zero real Linear HTTP traffic occurs. The private
  default `request_fun` on every `Linear.Client.graphql/3` call site is
  `post_graphql_request/2` — it is the single seam a real network request
  passes through, win or lose, since success logs nothing and only failure
  does. Tracing that local function call (installed at boot, before the
  application starts) rather than grepping logs catches both.
  """

  @tracer_name :symphony_elixir_linear_traffic_tracer
  @linear_mfa {SymphonyElixir.Linear.Client, :post_graphql_request, 2}

  @spec install!() :: :ok
  def install! do
    pid = spawn(fn -> loop(%{}) end)
    Process.register(pid, @tracer_name)

    trace_pattern!(@linear_mfa)
    :erlang.trace(:all, true, [:call, {:tracer, pid}])

    ExUnit.after_suite(fn _suite_result -> report!() end)
    :ok
  end

  @spec trace_pattern!({module(), atom(), non_neg_integer()}) :: :ok
  def trace_pattern!({module, function, arity} = mfa) when is_atom(module) and is_atom(function) and is_integer(arity) do
    :erlang.trace_pattern(mfa, true, [:local])
    :ok
  end

  @spec count() :: non_neg_integer()
  def count, do: count_for(@linear_mfa)

  @spec count_for({module(), atom(), non_neg_integer()}) :: non_neg_integer()
  def count_for(mfa) do
    send(Process.whereis(@tracer_name), {:count, mfa, self()})

    receive do
      {:count, ^mfa, n} -> n
    end
  end

  defp report! do
    n = count()
    IO.puts("[non-live sentinel] real Linear HTTP attempts (successful or failed): #{n}")

    if n > 0 do
      IO.puts(
        :stderr,
        "[non-live sentinel] FAILED: #{n} real Linear HTTP attempt(s) (successful or failed) " <>
          "reached SymphonyElixir.Linear.Client.post_graphql_request/2 during the non-live suite"
      )

      System.halt(1)
    end
  end

  defp loop(counts) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        key = {module, function, length(args)}
        loop(Map.update(counts, key, 1, &(&1 + 1)))

      {:count, mfa, from} ->
        send(from, {:count, mfa, Map.get(counts, mfa, 0)})
        loop(counts)
    end
  end
end
