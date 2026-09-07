defmodule SymphonyElixir.Runtime.ProcessOwnership.FileSystem do
  @moduledoc """
  Filesystem primitive used for atomic process-ownership record replacement.

  ProcessOwnership keeps ownership policy, serialization, temporary naming,
  and atomic rename ordering. This Seam only permits deterministic external-I/O
  latency in tests; the real filesystem Adapter is the production default.
  """

  @type mode :: :append | :compressed | :delayed_write | :exclusive | :raw | :sync | :write

  @callback write(Path.t(), iodata(), [mode()]) :: :ok | {:error, File.posix()}

  @spec write(Path.t(), iodata(), [mode()]) :: :ok | {:error, File.posix()}
  def write(path, contents, modes) do
    adapter().write(path, contents, modes)
  end

  defp adapter do
    Application.get_env(
      :symphony_elixir,
      :process_ownership_file_system,
      SymphonyElixir.Runtime.ProcessOwnership.FileSystem.Real
    )
  end
end

defmodule SymphonyElixir.Runtime.ProcessOwnership.FileSystem.Real do
  @moduledoc false

  @behaviour SymphonyElixir.Runtime.ProcessOwnership.FileSystem

  @impl true
  def write(path, contents, modes), do: File.write(path, contents, modes)
end
