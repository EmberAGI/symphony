defmodule SymphonyElixir.HostResourceContract do
  @moduledoc """
  Provider-neutral, immutable host-resource selection for one agent session.

  The integrating deployment supplies the declaration and the explicit source
  context. This Module validates both before returning exact local paths and
  command selections for provider launch Adapters.
  """

  import Bitwise

  @max_symlink_hops 16
  @top_level_fields ~w(schema_version role execution_generation runtime_generation operations)
  @operation_keys ~w(symphony_runtime_verification host_dns)
  @runtime_fields ~w(symphony_ref tool_config tool_config_sha256 mise elixir erlang)
  @mise_fields ~w(executable target sha256)
  @installation_fields ~w(version install_path)
  @dns_fields ~w(resolver_target)
  @dns_targets [
    "/etc/resolv.conf",
    "/run/systemd/resolve/stub-resolv.conf",
    "/run/systemd/resolve/resolv.conf"
  ]
  @forbidden_launcher_collections ~w(shims)
  @context_keys ~w(role execution_generation runtime_generation source_ref tool_config_path tool_config_sha256 worker_host)a

  defstruct role: nil,
            execution_generation: nil,
            runtime_generation: nil,
            operations: %{},
            read_paths: [],
            commands: %{},
            provenance: %{}

  @type t :: %__MODULE__{
          role: String.t() | nil,
          execution_generation: String.t() | nil,
          runtime_generation: pos_integer() | nil,
          operations: map(),
          read_paths: [Path.t()],
          commands: map(),
          provenance: map()
        }

  @doc "Resolve one explicit declaration into an immutable local contract."
  @spec resolve(nil | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(declaration, opts \\ []) when is_list(opts) do
    cond do
      is_nil(declaration) or (is_map(declaration) and map_size(declaration) == 0) ->
        {:ok, %__MODULE__{}}

      is_map(declaration) ->
        resolve_nonempty(declaration, opts)

      true ->
        invalid(:declaration, :malformed)
    end
  end

  @doc false
  @spec encode!(t()) :: String.t()
  def encode!(%__MODULE__{} = contract) do
    contract
    |> encoded_projection()
    |> Jason.encode!()
  end

  defp resolve_nonempty(declaration, opts) do
    with :ok <- validate_context_keys(opts),
         :ok <- validate_worker_host(opts),
         {:ok, declaration} <- normalize_map(declaration),
         :ok <- exact_keys(declaration, @top_level_fields, :declaration),
         :ok <- validate_schema_version(declaration["schema_version"]),
         {:ok, role} <- required_string(declaration["role"], :role),
         {:ok, execution_generation} <- required_string(declaration["execution_generation"], :execution_generation),
         {:ok, runtime_generation} <- positive_integer(declaration["runtime_generation"], :runtime_generation),
         :ok <- compare_context(:role, role, opts, [:role]),
         :ok <- compare_context(:execution_generation, execution_generation, opts, [:execution_generation]),
         :ok <- compare_context(:runtime_generation, runtime_generation, opts, [:runtime_generation]),
         {:ok, operations} <- resolve_operations(declaration["operations"], opts),
         {:ok, context} <- top_context(role, execution_generation, runtime_generation) do
      {:ok,
       %__MODULE__{
         role: role,
         execution_generation: execution_generation,
         runtime_generation: runtime_generation,
         operations: operations.values,
         read_paths: Enum.uniq(operations.read_paths),
         commands: operations.commands,
         provenance: Map.merge(context, operations.provenance)
       }}
    end
  end

  defp top_context(role, execution_generation, runtime_generation) do
    {:ok,
     %{
       role: role,
       execution_generation: execution_generation,
       runtime_generation: runtime_generation
     }}
  end

  defp resolve_operations(operations, opts) when is_map(operations) and map_size(operations) > 0 do
    with :ok <- validate_operation_keys(operations) do
      resolve_operation_entries(operations, opts)
    end
  end

  defp resolve_operations(_operations, _opts), do: invalid(:operations, :nonempty_map_required)

  defp validate_operation_keys(operations) do
    if Enum.all?(Map.keys(operations), &(&1 in @operation_keys)),
      do: :ok,
      else: invalid(:operations, :unsupported_operation)
  end

  defp resolve_operation_entries(operations, opts) do
    Enum.reduce_while(@operation_keys, {:ok, empty_operation_result()}, fn key, {:ok, result} ->
      case Map.fetch(operations, key) do
        :error ->
          {:cont, {:ok, result}}

        {:ok, operation} ->
          reduce_resolved_operation(key, operation, opts, result)
      end
    end)
  end

  defp reduce_resolved_operation(key, operation, opts, result) do
    case resolve_operation(key, operation, opts) do
      {:ok, operation_result} ->
        {:cont, {:ok, merge_operation_result(result, operation_result)}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp empty_operation_result do
    %{values: %{}, read_paths: [], commands: %{}, provenance: %{}}
  end

  defp merge_operation_result(result, operation_result) do
    %{
      values: Map.merge(result.values, operation_result.values),
      read_paths: result.read_paths ++ operation_result.read_paths,
      commands: Map.merge(result.commands, operation_result.commands),
      provenance: Map.merge(result.provenance, operation_result.provenance)
    }
  end

  defp resolve_operation("symphony_runtime_verification", operation, opts) do
    resolve_runtime_verification(operation, opts)
  end

  defp resolve_operation("host_dns", operation, _opts), do: resolve_host_dns(operation)

  defp resolve_runtime_verification(operation, opts) when is_map(operation) do
    with :ok <- exact_keys(operation, @runtime_fields, :symphony_runtime_verification),
         {:ok, symphony_ref} <- lower_hex(operation["symphony_ref"], 40, :symphony_ref),
         {:ok, tool_config} <- absolute_path(operation["tool_config"], :tool_config),
         {:ok, tool_config_sha256} <- lower_hex(operation["tool_config_sha256"], 64, :tool_config_sha256),
         :ok <- compare_context(:source_ref, symphony_ref, opts, [:source_ref]),
         :ok <- compare_context(:tool_config_path, tool_config, opts, [:tool_config_path]),
         :ok <- compare_context(:tool_config_sha256, tool_config_sha256, opts, [:tool_config_sha256]),
         {:ok, mise} <- validate_mise(operation["mise"]),
         {:ok, elixir} <- validate_installation(operation["elixir"], :elixir),
         {:ok, erlang} <- validate_installation(operation["erlang"], :erlang),
         :ok <- validate_version_relationship(elixir.version, erlang.version),
         {:ok, tool_config_canonical} <- canonical_regular_file(tool_config, :tool_config),
         :ok <- validate_tool_config(tool_config_canonical, elixir.version, erlang.version),
         {:ok, tool_config_digest} <- file_digest(tool_config_canonical, :tool_config),
         :ok <- compare_digest(tool_config_digest, tool_config_sha256, :tool_config_sha256),
         {:ok, mise_result} <- resolve_mise(mise),
         {:ok, elixir_result} <- resolve_installation(elixir, :elixir),
         {:ok, erlang_result} <- resolve_installation(erlang, :erlang) do
      values = %{
        "symphony_runtime_verification" => %{
          "symphony_ref" => symphony_ref,
          "tool_config" => tool_config,
          "tool_config_sha256" => tool_config_sha256,
          "mise" => mise,
          "elixir" => elixir,
          "erlang" => erlang
        }
      }

      {:ok,
       %{
         values: values,
         read_paths:
           [tool_config] ++
             mise_result.read_paths ++
             elixir_result.read_paths ++ erlang_result.read_paths,
         commands: %{
           mise: mise_result.command,
           elixir: elixir_result.command,
           erlang: erlang_result.command
         },
         provenance: %{
           symphony_ref: symphony_ref,
           tool_config_path: tool_config,
           tool_config_sha256: tool_config_sha256,
           mise_sha256: mise.sha256
         }
       }}
    end
  end

  defp resolve_runtime_verification(_operation, _opts),
    do: invalid(:symphony_runtime_verification, :map_required)

  defp resolve_host_dns(operation) when is_map(operation) do
    with :ok <- exact_keys(operation, @dns_fields, :host_dns),
         {:ok, resolver_target} <- absolute_path(operation["resolver_target"], :resolver_target),
         :ok <- validate_dns_target(resolver_target),
         {:ok, resolver_entry} <- canonical_path("/etc/resolv.conf", :resolver_entry),
         {:ok, target} <- canonical_path(resolver_target, :resolver_target),
         :ok <- if(target == resolver_target, do: :ok, else: invalid(:resolver_target, :not_canonical)),
         :ok <- if(resolver_entry == resolver_target, do: :ok, else: invalid(:resolver_target, :entry_mismatch)),
         :ok <- validate_regular_file(target, :resolver_target, false) do
      {:ok,
       %{
         values: %{"host_dns" => %{"resolver_target" => resolver_target}},
         read_paths: Enum.uniq(["/etc/resolv.conf", resolver_target]),
         commands: %{},
         provenance: %{resolver_target: resolver_target}
       }}
    end
  end

  defp resolve_host_dns(_operation), do: invalid(:host_dns, :map_required)

  defp validate_dns_target(target) do
    if target in @dns_targets, do: :ok, else: invalid(:resolver_target, :unsupported_target)
  end

  defp validate_mise(value) when is_map(value) do
    with :ok <- exact_keys(value, @mise_fields, :mise),
         {:ok, executable} <- absolute_path(value["executable"], :mise_executable),
         {:ok, target} <- absolute_path(value["target"], :mise_target),
         {:ok, sha256} <- lower_hex(value["sha256"], 64, :mise_sha256) do
      {:ok, %{executable: executable, target: target, sha256: sha256}}
    end
  end

  defp validate_mise(_value), do: invalid(:mise, :map_required)

  defp validate_installation(value, kind) when is_map(value) do
    with :ok <- exact_keys(value, @installation_fields, kind),
         {:ok, version} <- installed_version(value["version"], kind),
         {:ok, install_path} <- absolute_path(value["install_path"], {kind, :install_path}),
         :ok <- validate_install_layout(install_path, version, kind) do
      {:ok, %{version: version, install_path: install_path}}
    end
  end

  defp validate_installation(_value, kind), do: invalid(kind, :map_required)

  defp validate_install_layout(path, version, kind) do
    expected_parent = Atom.to_string(kind)
    installs_path = path |> Path.dirname() |> Path.dirname()

    cond do
      Path.expand(path) != path -> invalid({kind, :install_path}, :not_canonical)
      Path.basename(path) != version -> invalid({kind, :install_path}, :version_path_mismatch)
      Path.basename(Path.dirname(path)) != expected_parent -> invalid({kind, :install_path}, :layout_mismatch)
      Path.basename(installs_path) != "installs" -> invalid({kind, :install_path}, :layout_mismatch)
      true -> :ok
    end
  end

  defp installed_version(value, kind) when is_binary(value) do
    cond do
      value == "" or String.trim(value) != value -> invalid({kind, :version}, :blank)
      kind == :elixir and not Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+-otp-[0-9]+\z/, value) -> invalid({kind, :version}, :unsupported_version)
      kind == :erlang and not Regex.match?(~r/\A[1-9][0-9]*(?:\.[0-9]+)+\z/, value) -> invalid({kind, :version}, :unsupported_version)
      true -> {:ok, value}
    end
  end

  defp installed_version(_value, kind), do: invalid({kind, :version}, :invalid_type)

  defp validate_version_relationship(elixir_version, erlang_version) do
    case Regex.run(~r/-otp-([0-9]+)\z/, elixir_version, capture: :all_but_first) do
      [otp_major] ->
        if otp_major == erlang_major(erlang_version), do: :ok, else: invalid(:versions, :incompatible)

      _ ->
        invalid(:versions, :incompatible)
    end
  end

  defp validate_tool_config(path, elixir_version, erlang_version) do
    with {:ok, contents} <- read_file(path, :tool_config),
         {:ok, decoded} <- decode_toml(contents),
         :ok <- exact_keys(decoded, ["tools"], :tool_config),
         {:ok, tools} <- required_map(decoded["tools"], :tools),
         :ok <- exact_keys(tools, ["elixir", "erlang"], :tools),
         {:ok, configured_elixir} <- pinned_tool(tools["elixir"], :elixir),
         {:ok, configured_erlang} <- pinned_tool(tools["erlang"], :erlang),
         :ok <- if(configured_elixir == elixir_version, do: :ok, else: invalid(:elixir, :version_mismatch)) do
      if(configured_erlang == erlang_major(erlang_version),
        do: :ok,
        else: invalid(:erlang, :version_mismatch)
      )
    end
  end

  defp erlang_major(version), do: version |> String.split(".", parts: 2) |> hd()

  defp decode_toml(contents) do
    case Toml.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> invalid(:tool_config, :invalid_toml)
    end
  end

  defp pinned_tool(value, kind) when is_binary(value) do
    cond do
      value == "" or String.trim(value) != value -> invalid(kind, :blank)
      String.contains?(value, ["{{", "}}", "latest", "~", "^", "*", " "]) -> invalid(kind, :dynamic_selector)
      kind == :erlang and not Regex.match?(~r/\A[1-9][0-9]*\z/, value) -> invalid(kind, :unsupported_version)
      kind == :elixir and not Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+-otp-[0-9]+\z/, value) -> invalid(kind, :unsupported_version)
      true -> {:ok, value}
    end
  end

  defp pinned_tool(_value, kind), do: invalid(kind, :pinned_string_required)

  defp resolve_mise(%{executable: executable, target: target, sha256: expected_digest}) do
    with :ok <- reject_forbidden_launcher_collection(executable, :mise_executable),
         :ok <- reject_forbidden_launcher_collection(target, :mise_target),
         {:ok, executable_canonical} <- canonical_path(executable, :mise_executable),
         {:ok, target_canonical} <- canonical_path(target, :mise_target),
         :ok <- if(target_canonical == target, do: :ok, else: invalid(:mise_target, :not_canonical)),
         :ok <- if(executable_canonical == target, do: :ok, else: invalid(:mise_executable, :target_mismatch)),
         :ok <- validate_regular_file(target, :mise_target, true),
         {:ok, digest} <- file_digest(target, :mise_target),
         :ok <- compare_digest(digest, expected_digest, :mise_sha256) do
      {:ok, %{read_paths: [executable, target], command: executable}}
    end
  end

  defp reject_forbidden_launcher_collection(path, resource) do
    if Enum.any?(Path.split(path), &(&1 in @forbidden_launcher_collections)),
      do: invalid(resource, :unsafe_root),
      else: :ok
  end

  defp resolve_installation(%{version: version, install_path: install_path}, kind) do
    with {:ok, canonical_install_path} <- canonical_path(install_path, {kind, :install_path}),
         :ok <-
           if(canonical_install_path == install_path,
             do: :ok,
             else: invalid({kind, :install_path}, :not_canonical)
           ),
         :ok <- validate_directory(install_path, {kind, :install_path}),
         {:ok, command, command_read_paths} <- resolve_install_command(install_path, kind),
         :ok <-
           if(Path.basename(install_path) == version,
             do: :ok,
             else: invalid({kind, :install_path}, :version_path_mismatch)
           ) do
      {:ok, %{version: version, read_paths: [install_path | command_read_paths], command: command}}
    end
  end

  defp resolve_install_command(install_path, :elixir) do
    resolve_installed_command(Path.join([install_path, "bin", "elixir"]), :elixir)
  end

  defp resolve_install_command(install_path, :erlang) do
    resolve_installed_command(Path.join([install_path, "bin", "erl"]), :erlang)
  end

  defp resolve_installed_command(path, kind) do
    with {:ok, canonical} <- canonical_path(path, {kind, :executable}),
         :ok <- if(canonical == path, do: :ok, else: invalid({kind, :executable}, :not_canonical)),
         :ok <- validate_regular_file(path, {kind, :executable}, true) do
      {:ok, path, [Path.dirname(path), path]}
    end
  end

  defp canonical_regular_file(path, resource) do
    with {:ok, canonical} <- canonical_path(path, resource),
         :ok <- if(canonical == path, do: :ok, else: invalid(resource, :not_canonical)),
         :ok <- validate_regular_file(path, resource, false) do
      {:ok, canonical}
    end
  end

  defp validate_regular_file(path, resource, executable?) do
    with :ok <- validate_searchable_parents(path, resource),
         {:ok, stat} <- lstat(path, resource),
         :ok <- if(stat.type == :regular, do: :ok, else: invalid(resource, :wrong_type)),
         :ok <- require_mode(stat.mode, 0o444, resource, :unreadable) do
      if(executable?, do: require_mode(stat.mode, 0o111, resource, :non_executable), else: :ok)
    end
  end

  defp validate_directory(path, resource) do
    with :ok <- validate_searchable_parents(path, resource),
         {:ok, stat} <- lstat(path, resource),
         :ok <- if(stat.type == :directory, do: :ok, else: invalid(resource, :wrong_type)),
         :ok <- require_mode(stat.mode, 0o444, resource, :unreadable) do
      require_mode(stat.mode, 0o111, resource, :unsearchable)
    end
  end

  defp validate_searchable_parents(path, resource) do
    case Path.dirname(path) do
      "/" ->
        :ok

      parent ->
        with {:ok, stat} <- lstat(parent, resource),
             :ok <- validate_parent_directory(stat, resource),
             :ok <- require_mode(stat.mode, 0o111, resource, :unsearchable) do
          validate_searchable_parents(parent, resource)
        end
    end
  end

  defp validate_parent_directory(%File.Stat{type: :directory}, _resource), do: :ok
  defp validate_parent_directory(_stat, resource), do: invalid(resource, :parent_not_directory)

  defp require_mode(mode, mask, resource, reason) do
    if (mode &&& mask) != 0, do: :ok, else: invalid(resource, reason)
  end

  defp lstat(path, resource) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> invalid(resource, :missing)
      {:error, :eacces} -> invalid(resource, :unreadable)
      {:error, _reason} -> invalid(resource, :unreadable)
    end
  end

  defp read_file(path, resource) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> invalid(resource, :missing)
      {:error, :eacces} -> invalid(resource, :unreadable)
      {:error, _reason} -> invalid(resource, :unreadable)
    end
  end

  defp file_digest(path, resource) do
    with {:ok, contents} <- read_file(path, resource) do
      {:ok, :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)}
    end
  end

  defp compare_digest(actual, expected, resource) do
    if actual == expected, do: :ok, else: invalid(resource, :digest_mismatch)
  end

  defp canonical_path(path, resource) do
    case resolve_symlinks(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> invalid(resource, reason)
    end
  end

  defp resolve_symlinks(path) do
    {root, segments} = split_absolute_path(path)
    resolve_segments(root, [], segments, 0, [])
  end

  defp split_absolute_path(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  @spec resolve_segments(
          String.t(),
          [String.t()],
          [String.t()],
          non_neg_integer(),
          [String.t()]
        ) :: {:ok, String.t()} | {:error, atom()}
  defp resolve_segments(root, resolved_segments, [], _hops, _seen),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], hops, seen) do
    candidate = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(candidate, rest, hops, seen)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, hops, seen)

      {:error, :enoent} ->
        {:error, :missing}

      {:error, :eacces} ->
        {:error, :unreadable}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  @spec resolve_symlink(String.t(), [String.t()], non_neg_integer(), [String.t()]) ::
          {:ok, String.t()} | {:error, atom()}
  defp resolve_symlink(candidate, rest, hops, seen) do
    cond do
      hops >= @max_symlink_hops -> {:error, :symlink_hops_exceeded}
      candidate in seen -> {:error, :symlink_cycle}
      true -> follow_symlink(candidate, rest, hops, seen)
    end
  end

  @spec follow_symlink(String.t(), [String.t()], non_neg_integer(), [String.t()]) ::
          {:ok, String.t()} | {:error, atom()}
  defp follow_symlink(candidate, rest, hops, seen) do
    case :file.read_link_all(String.to_charlist(candidate)) do
      {:ok, target} ->
        expanded_target = Path.expand(IO.chardata_to_string(target), Path.dirname(candidate))
        {target_root, target_segments} = split_absolute_path(expanded_target)

        resolve_segments(
          target_root,
          [],
          target_segments ++ rest,
          hops + 1,
          [candidate | seen]
        )

      {:error, :enoent} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp join_path(root, segments), do: Enum.reduce(segments, root, &Path.join(&2, &1))

  defp compare_context(resource, actual, opts, keys) do
    case explicit_option(opts, keys) do
      :missing -> invalid(resource, :missing_context)
      {:ok, expected} when expected == actual -> :ok
      {:ok, _expected} -> invalid(resource, :mismatch)
    end
  end

  defp explicit_option(opts, keys) do
    case Enum.find(keys, &Keyword.has_key?(opts, &1)) do
      nil -> :missing
      key -> {:ok, Keyword.get(opts, key)}
    end
  end

  defp validate_context_keys(opts) do
    if Enum.all?(Keyword.keys(opts), &(&1 in @context_keys)) do
      :ok
    else
      invalid(:context, :unsupported_context_key)
    end
  end

  defp validate_worker_host(opts) do
    case Keyword.get(opts, :worker_host) do
      nil -> :ok
      "" -> :ok
      value when is_binary(value) -> invalid(:worker_host, :remote_unsupported)
      _value -> invalid(:worker_host, :invalid_type)
    end
  end

  defp validate_schema_version(1), do: :ok
  defp validate_schema_version(_value), do: invalid(:schema_version, :unsupported)

  defp required_string(value, resource) when is_binary(value) do
    if value != "" and String.trim(value) == value,
      do: {:ok, value},
      else: invalid(resource, :blank)
  end

  defp required_string(_value, resource), do: invalid(resource, :invalid_type)

  defp positive_integer(value, _resource) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, resource), do: invalid(resource, :invalid_type)

  defp absolute_path(value, resource) when is_binary(value) do
    cond do
      value == "" or String.trim(value) != value -> invalid(resource, :blank)
      Path.type(value) != :absolute -> invalid(resource, :not_absolute)
      Path.expand(value) != value -> invalid(resource, :not_canonical)
      true -> {:ok, value}
    end
  end

  defp absolute_path(_value, resource), do: invalid(resource, :invalid_type)

  defp lower_hex(value, length, resource) when is_binary(value) do
    if byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value),
      do: {:ok, value},
      else: invalid(resource, :invalid_digest)
  end

  defp lower_hex(_value, _length, resource), do: invalid(resource, :invalid_digest)

  defp exact_keys(value, expected, resource) when is_map(value) do
    if MapSet.new(Map.keys(value)) == MapSet.new(expected),
      do: :ok,
      else: invalid(resource, :invalid_fields)
  end

  defp exact_keys(_value, _expected, resource), do: invalid(resource, :map_required)

  defp required_map(value, _resource) when is_map(value), do: {:ok, value}
  defp required_map(_value, resource), do: invalid(resource, :map_required)

  defp normalize_map(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, normalized} ->
      with {:ok, normalized_key} <- normalize_key(key),
           false <- Map.has_key?(normalized, normalized_key),
           {:ok, normalized_value} <- normalize_nested(nested) do
        {:cont, {:ok, Map.put(normalized, normalized_key, normalized_value)}}
      else
        true -> {:halt, invalid(:declaration, :duplicate_field)}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: invalid(:declaration, :invalid_field)

  defp normalize_nested(value) when is_map(value), do: normalize_map(value)
  defp normalize_nested(value), do: {:ok, value}

  defp encoded_projection(%__MODULE__{} = contract) do
    Jason.OrderedObject.new([
      {"commands", ordered_map(contract.commands)},
      {"operations", ordered_map(contract.operations)},
      {"provenance", ordered_map(contract.provenance)},
      {"read_paths", contract.read_paths}
    ])
  end

  defp ordered_map(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), encoded_value(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp encoded_value(value) when is_map(value), do: ordered_map(value)
  defp encoded_value(value) when is_list(value), do: Enum.map(value, &encoded_value/1)
  defp encoded_value(value), do: value

  defp invalid(resource, reason) do
    {:error, {:invalid_host_resource_contract, %{resource: resource, reason: reason}}}
  end
end
