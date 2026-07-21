defmodule SymphonyElixir.SkillExecutionContract do
  @moduledoc """
  Validates and normalizes the exact read-only runtime resources registered for
  configured skills.

  The integrating workflow owns registration. This Module owns only the
  provider-neutral value consumed by `AgentRuntime` and provider Adapters.
  """

  import Bitwise
  alias SymphonyElixir.{PathSafety, SSH}

  @enforce_keys [:skill, :package_root]
  defstruct [:skill, :package_root, runtime_inputs: [], tool_executables: []]

  @type t :: %__MODULE__{
          skill: String.t(),
          package_root: Path.t(),
          runtime_inputs: [Path.t()],
          tool_executables: [Path.t()]
        }

  @doc "Resolve integration-supplied records into one provider-neutral value."
  @spec resolve([map()], keyword()) :: {:ok, [t()]} | {:error, term()}
  def resolve(entries, opts \\ []) do
    if is_list(entries), do: resolve_entries(entries, opts), else: {:error, :invalid_skill_execution_contracts}
  end

  defp resolve_entries(entries, opts) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, contracts} ->
      case resolve_entry(entry, opts) do
        {:ok, contract} -> {:cont, {:ok, [contract | contracts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, contracts} ->
        contracts
        |> Enum.reverse()
        |> reject_conflicting_skills()
        |> reject_cross_contract_access_conflicts()
        |> validate_remote(opts)

      error ->
        error
    end
  end

  @doc "Return every exact registered path in provider projection order."
  @spec read_paths([t()]) :: [Path.t()]
  def read_paths(contracts) when is_list(contracts) do
    contracts
    |> Enum.flat_map(fn contract ->
      [contract.package_root | contract.runtime_inputs ++ contract.tool_executables]
    end)
    |> Enum.uniq()
  end

  @doc "Encode normalized contracts for provider-native launch environments."
  @spec encode!([t()]) :: String.t()
  def encode!(contracts) when is_list(contracts) do
    contracts
    |> Enum.map(fn contract ->
      %{
        skill: contract.skill,
        package_root: contract.package_root,
        runtime_inputs: contract.runtime_inputs,
        tool_executables: contract.tool_executables
      }
    end)
    |> Jason.encode!()
  end

  defp resolve_entry(entry, opts) when is_map(entry) do
    skill = normalized_skill(value(entry, :skill))

    with {:ok, skill} <- required_skill(skill),
         {:ok, package_root} <- required_path(value(entry, :package_root), skill, :package_root),
         {:ok, runtime_inputs} <- path_list(value(entry, :runtime_inputs) || [], skill, :runtime_inputs),
         {:ok, tool_executables} <- path_list(value(entry, :tool_executables) || [], skill, :tool_executables),
         :ok <- reject_conflicting_access(skill, runtime_inputs, tool_executables),
         :ok <- validate_package_root(skill, package_root, opts),
         :ok <- validate_runtime_inputs(skill, runtime_inputs, opts),
         :ok <- validate_tool_executables(skill, tool_executables, opts) do
      {:ok,
       %__MODULE__{
         skill: skill,
         package_root: package_root,
         runtime_inputs: runtime_inputs,
         tool_executables: tool_executables
       }}
    end
  end

  defp resolve_entry(_entry, _opts), do: invalid("unknown", :contract, :malformed)

  defp normalized_skill(skill) when is_binary(skill), do: String.trim(skill)
  defp normalized_skill(_skill), do: "unknown"

  defp required_skill(""), do: invalid("unknown", :skill, :missing)
  defp required_skill("unknown"), do: invalid("unknown", :skill, :missing)
  defp required_skill(skill), do: {:ok, skill}

  defp required_path(nil, skill, field), do: invalid(skill, field, :missing)

  defp required_path(path, skill, field) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, Path.expand(path)},
      else: invalid(skill, field, :not_absolute)
  end

  defp required_path(_path, skill, field), do: invalid(skill, field, :malformed)

  defp path_list(paths, skill, field) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, resolved} ->
      case required_path(path, skill, field) do
        {:ok, absolute} -> {:cont, {:ok, [absolute | resolved]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp path_list(_paths, skill, field), do: invalid(skill, field, :malformed)

  defp reject_conflicting_access(skill, runtime_inputs, tool_executables) do
    if MapSet.disjoint?(MapSet.new(runtime_inputs), MapSet.new(tool_executables)),
      do: :ok,
      else: invalid(skill, :resources, :conflicting_access)
  end

  defp validate_package_root(skill, path, opts) do
    cond do
      broad_root?(path, opts) -> invalid(skill, :package_root, :broad_root)
      denied?(path, opts) -> invalid(skill, :package_root, :denied)
      symlinked?(path) -> invalid(skill, :package_root, :symlink_escape)
      true -> validate_stat(skill, :package_root, path, :directory, true)
    end
  end

  defp validate_runtime_inputs(skill, paths, opts) do
    validate_paths(skill, :runtime_inputs, paths, opts, false)
  end

  defp validate_tool_executables(skill, paths, opts) do
    validate_paths(skill, :tool_executables, paths, opts, true)
  end

  defp validate_paths(skill, field, paths, opts, executable?) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      result =
        cond do
          denied?(path, opts) -> invalid(skill, field, :denied)
          symlinked?(path) -> invalid(skill, field, :symlink_escape)
          true -> validate_stat(skill, field, path, :regular, executable?)
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_stat(skill, field, path, expected_type, executable?) do
    case File.stat(path) do
      {:ok, %{type: ^expected_type, mode: mode}} ->
        validate_mode(skill, field, path, mode, expected_type, executable?)

      {:ok, _stat} ->
        invalid(skill, field, :wrong_type)

      {:error, :enoent} ->
        invalid(skill, field, :missing)

      {:error, :eacces} ->
        invalid(skill, field, :unreadable)

      {:error, _reason} ->
        invalid(skill, field, :unreadable)
    end
  end

  defp validate_mode(skill, field, path, mode, expected_type, executable?) do
    with :ok <- require_access(skill, field, path, mode, 0o444, :read, :unreadable),
         :ok <- require_directory_access(skill, field, path, mode, expected_type) do
      require_executable_access(skill, field, path, mode, executable?)
    end
  end

  defp require_directory_access(skill, field, path, mode, :directory) do
    require_access(skill, field, path, mode, 0o111, :execute, :unreadable)
  end

  defp require_directory_access(_skill, _field, _path, _mode, _expected_type), do: :ok

  defp require_executable_access(skill, field, path, mode, true) do
    require_access(skill, field, path, mode, 0o111, :execute, :non_executable)
  end

  defp require_executable_access(_skill, _field, _path, _mode, false), do: :ok

  defp require_access(skill, field, path, mode, mask, access, reason) do
    if (mode &&& mask) != 0 and accessible?(path, access),
      do: :ok,
      else: invalid(skill, field, reason)
  end

  defp broad_root?(path, opts) do
    orchestration_root = Keyword.get(opts, :orchestration_root)

    canonical_path = canonical_path(path)

    broad =
      ["/", System.user_home!()]
      |> maybe_add_broad_roots(orchestration_root)
      |> Enum.map(&canonical_path/1)

    canonical_path in broad
  end

  defp maybe_add_broad_roots(roots, root) when is_binary(root) and root != "" do
    expanded = Path.expand(root)
    roots ++ [expanded, Path.join(expanded, ".agents"), Path.join([expanded, ".agents", "skills"])]
  end

  defp maybe_add_broad_roots(roots, _root), do: roots

  defp denied?(path, opts) do
    case Keyword.get(opts, :selected_workspace) do
      root when is_binary(root) and root != "" -> within?(canonical_path(path), canonical_path(root))
      _ -> false
    end
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp canonical_path(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> canonical_path
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp accessible?(path, access) do
    flag = if access == :read, do: "-r", else: "-x"

    case System.find_executable("test") do
      nil ->
        false

      executable ->
        match?({_output, 0}, System.cmd(executable, [flag, path], stderr_to_stdout: true))
    end
  end

  defp symlinked?(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn segment, current ->
      next = if is_nil(current), do: segment, else: Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} -> {:halt, true}
        _ -> {:cont, next}
      end
    end)
    |> Kernel.==(true)
  end

  defp reject_conflicting_skills(contracts) do
    contracts
    |> Enum.reduce_while({:ok, %{}, []}, fn contract, {:ok, by_skill, resolved} ->
      case Map.fetch(by_skill, contract.skill) do
        :error ->
          {:cont, {:ok, Map.put(by_skill, contract.skill, contract), [contract | resolved]}}

        {:ok, ^contract} ->
          {:cont, {:ok, by_skill, resolved}}

        {:ok, _different} ->
          {:halt, invalid(contract.skill, :contract, :conflict)}
      end
    end)
    |> case do
      {:ok, _by_skill, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp reject_cross_contract_access_conflicts({:error, _reason} = error), do: error

  defp reject_cross_contract_access_conflicts({:ok, contracts}) do
    accesses =
      Enum.reduce(contracts, %{}, fn contract, accesses ->
        accesses
        |> record_access(contract.package_root, :package_root)
        |> record_accesses(contract.runtime_inputs, :runtime_input)
        |> record_accesses(contract.tool_executables, :tool_executable)
      end)

    if Enum.any?(accesses, fn {_path, kinds} -> MapSet.size(kinds) > 1 end),
      do: invalid("multiple", :resources, :conflicting_access),
      else: {:ok, contracts}
  end

  defp record_accesses(accesses, paths, kind) do
    Enum.reduce(paths, accesses, &record_access(&2, &1, kind))
  end

  defp record_access(accesses, path, kind) do
    Map.update(accesses, path, MapSet.new([kind]), &MapSet.put(&1, kind))
  end

  defp validate_remote({:error, _reason} = error, _opts), do: error

  defp validate_remote({:ok, []}, _opts), do: {:ok, []}

  defp validate_remote({:ok, contracts}, opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) and host != "" ->
        validate_remote_contracts(host, contracts, Keyword.get(opts, :remote_validator))

      _ ->
        {:ok, contracts}
    end
  end

  defp validate_remote_contracts(host, contracts, validator) do
    validator = if is_function(validator, 2), do: validator, else: &remote_materialized?/2

    case validator.(host, contracts) do
      :ok -> {:ok, contracts}
      _ -> invalid(first_skill(contracts), :resources, :remote_unmaterialized)
    end
  end

  defp first_skill([contract | _contracts]), do: contract.skill
  defp first_skill([]), do: "unknown"

  defp remote_materialized?(host, contracts) do
    checks =
      Enum.flat_map(contracts, fn contract ->
        [remote_check(contract.package_root, :directory)] ++
          Enum.map(contract.runtime_inputs, &remote_check(&1, :file)) ++
          Enum.map(contract.tool_executables, &remote_check(&1, :executable))
      end)

    command = Enum.join(["set -eu" | checks], "\n")

    case SSH.run(host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      _ -> {:error, :remote_unmaterialized}
    end
  end

  defp remote_check(path, kind) do
    escaped = shell_escape(path)

    type_check =
      case kind do
        :directory -> "test -d #{escaped} && test -x #{escaped}"
        :file -> "test -f #{escaped}"
        :executable -> "test -f #{escaped} && test -x #{escaped}"
      end

    "#{type_check} && test -r #{escaped} && test \"$(readlink -f -- #{escaped})\" = #{escaped}"
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp invalid(skill, field, reason) do
    {:error,
     {:invalid_skill_execution_contract,
      %{
        skill: skill,
        field: field,
        reason: reason
      }}}
  end

  defp value(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
end
