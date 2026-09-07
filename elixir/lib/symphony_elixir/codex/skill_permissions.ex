defmodule SymphonyElixir.Codex.SkillPermissions do
  @moduledoc """
  Projects registered skill resources and their native Codex discovery path
  without granting the rest of the provider home.
  """

  alias SymphonyElixir.SkillExecutionContract

  @spec read_paths([SkillExecutionContract.t()], String.t() | nil) :: [Path.t()]
  def read_paths(contracts, codex_home) do
    paths = SkillExecutionContract.read_paths(contracts)

    if paths != [] and is_binary(codex_home) and Path.type(codex_home) == :absolute do
      Enum.uniq(paths ++ [Path.join(codex_home, "skills")])
    else
      paths
    end
  end
end
