defmodule SymphonyElixir.HostResourceContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.HostResourceContract

  setup do
    root = Path.join(System.tmp_dir!(), "host-resource-contract-#{System.unique_integer([:positive])}")
    tool_config = Path.join(root, "mise.toml")
    mise_bin = Path.join([root, "mise", "bin", "mise"])
    mise_target = Path.join([root, "mise", "targets", "mise-2026.09"])
    elixir_install = Path.join([root, "mise", "installs", "elixir", "1.19.5-otp-28"])
    erlang_install = Path.join([root, "mise", "installs", "erlang", "28.5"])

    File.mkdir_p!(Path.dirname(mise_bin))
    File.mkdir_p!(Path.dirname(mise_target))
    File.mkdir_p!(Path.join(elixir_install, "bin"))
    File.mkdir_p!(Path.join(erlang_install, "bin"))

    File.write!(tool_config, "[tools]\nerlang = \"28\"\nelixir = \"1.19.5-otp-28\"\n")
    File.write!(mise_target, "#!/bin/sh\nexit 0\n")
    File.ln_s!(mise_target, mise_bin)
    File.write!(Path.join(elixir_install, "bin/elixir"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(erlang_install, "bin/erl"), "#!/bin/sh\nexit 0\n")

    File.chmod!(mise_target, 0o755)
    File.chmod!(Path.join(elixir_install, "bin/elixir"), 0o755)
    File.chmod!(Path.join(erlang_install, "bin/erl"), 0o755)

    on_exit(fn -> File.rm_rf!(root) end)

    declaration = %{
      "schema_version" => 1,
      "role" => "implementer",
      "execution_generation" => "exec-20260906",
      "runtime_generation" => 7,
      "operations" => %{
        "symphony_runtime_verification" => %{
          "symphony_ref" => String.duplicate("a", 40),
          "tool_config" => tool_config,
          "tool_config_sha256" => digest(tool_config),
          "mise" => %{
            "executable" => mise_bin,
            "target" => mise_target,
            "sha256" => digest(mise_target)
          },
          "elixir" => %{
            "version" => "1.19.5-otp-28",
            "install_path" => elixir_install
          },
          "erlang" => %{
            "version" => "28.5",
            "install_path" => erlang_install
          }
        }
      }
    }

    %{declaration: declaration, root: root, tool_config: tool_config, mise_bin: mise_bin, mise_target: mise_target}
  end

  test "resolves an absent declaration as an immutable no-op" do
    assert {:ok, %HostResourceContract{} = contract} = HostResourceContract.resolve(%{}, [])
    assert contract.operations == %{}
    assert contract.read_paths == []
    assert contract.commands == %{}
    assert {:ok, %HostResourceContract{}} = HostResourceContract.resolve(nil, [])
  end

  test "resolves explicit local runtime resources into one immutable contract", context do
    assert {:ok, %HostResourceContract{} = contract} =
             HostResourceContract.resolve(context.declaration,
               role: "implementer",
               execution_generation: "exec-20260906",
               runtime_generation: 7,
               source_ref: String.duplicate("a", 40),
               tool_config_path: context.tool_config,
               tool_config_sha256: context.declaration["operations"]["symphony_runtime_verification"]["tool_config_sha256"]
             )

    assert contract.role == "implementer"
    assert contract.execution_generation == "exec-20260906"
    assert contract.runtime_generation == 7
    assert context.tool_config in contract.read_paths
    assert context.mise_bin in contract.read_paths
    assert context.mise_target in contract.read_paths
    assert contract.commands[:elixir] == Path.join([context.declaration["operations"]["symphony_runtime_verification"]["elixir"]["install_path"], "bin", "elixir"])
    assert contract.commands[:erlang] == Path.join([context.declaration["operations"]["symphony_runtime_verification"]["erlang"]["install_path"], "bin", "erl"])
  end

  test "classifies invalid host resources as irrecoverable configuration" do
    assert {:irrecoverable, failure} =
             AgentRuntime.classify_failure(
               {:invalid_host_resource_contract, %{resource: :mise_target, reason: :missing, detail: "secret-host-path"}},
               %{provider: :codex}
             )

    assert failure.family == :missing_required_runtime_configuration
    assert failure.retryable? == false
    refute failure.summary =~ "secret-host-path"
    refute failure.retry_reason =~ "secret-host-path"
  end

  test "compares each explicit provenance value independently and rejects remote workers", context do
    opts = runtime_opts(context)

    for {key, value, resource} <- [
          {:role, "reviewer", :role},
          {:execution_generation, "exec-other", :execution_generation},
          {:runtime_generation, 8, :runtime_generation},
          {:source_ref, String.duplicate("b", 40), :source_ref},
          {:tool_config_path, Path.join(context.root, "other-mise.toml"), :tool_config_path},
          {:tool_config_sha256, String.duplicate("d", 64), :tool_config_sha256}
        ] do
      assert {:error, {:invalid_host_resource_contract, %{resource: ^resource, reason: :mismatch}}} =
               HostResourceContract.resolve(context.declaration, Keyword.put(opts, key, value))
    end

    for key <- [
          :role,
          :execution_generation,
          :runtime_generation,
          :source_ref,
          :tool_config_path,
          :tool_config_sha256
        ] do
      assert {:error, {:invalid_host_resource_contract, %{reason: :missing_context}}} =
               HostResourceContract.resolve(context.declaration, Keyword.delete(opts, key))
    end

    assert {:error, {:invalid_host_resource_contract, %{resource: :worker_host, reason: :remote_unsupported}}} =
             HostResourceContract.resolve(context.declaration, Keyword.put(opts, :worker_host, "worker-1"))
  end

  test "rejects malformed nested declarations and never returns secret paths", context do
    opts = runtime_opts(context)
    secret_path = Path.join(context.root, "provider-secret-token")

    invalid_declarations = [
      Map.put(context.declaration, "unexpected", secret_path),
      Map.put(context.declaration, "operations", %{"unsupported" => %{}}),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "unexpected"], secret_path),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "mise", "sha256"], String.duplicate("A", 64)),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "elixir", "version"], "latest"),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "erlang", "install_path"], secret_path),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "tool_config"], "relative/mise.toml"),
      put_in(context.declaration, ["operations", "symphony_runtime_verification", "symphony_ref"], String.duplicate("a", 39))
    ]

    for declaration <- invalid_declarations do
      error = HostResourceContract.resolve(declaration, opts)
      assert {:error, {:invalid_host_resource_contract, _details}} = error
      refute inspect(error) =~ secret_path
    end

    error = HostResourceContract.resolve(context.declaration, Keyword.put(opts, :tool_config_sha256, String.duplicate("e", 64)))
    refute inspect(error) =~ secret_path
  end

  test "rejects a digest mismatch and unreadable or non-executable mise targets", context do
    opts = runtime_opts(context)
    verification = context.declaration["operations"]["symphony_runtime_verification"]

    with_bad_digest = put_in(context.declaration, ["operations", "symphony_runtime_verification", "mise", "sha256"], String.duplicate("d", 64))

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_sha256, reason: :digest_mismatch}}} =
             HostResourceContract.resolve(with_bad_digest, opts)

    File.chmod!(context.mise_target, 0o644)

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_target, reason: :non_executable}}} =
             HostResourceContract.resolve(context.declaration, opts)

    File.chmod!(context.mise_target, 0o755)
    missing_target = Path.join(context.root, "missing-mise")
    missing = put_in(context.declaration, ["operations", "symphony_runtime_verification", "mise", "target"], missing_target)
    missing = put_in(missing, ["operations", "symphony_runtime_verification", "mise", "executable"], missing_target)

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :missing}}} =
             HostResourceContract.resolve(missing, opts)

    assert verification["mise"]["target"] == context.mise_target

    File.chmod!(context.tool_config, 0o000)

    assert {:error, {:invalid_host_resource_contract, %{resource: :tool_config, reason: :unreadable}}} =
             HostResourceContract.resolve(context.declaration, opts)
  end

  test "rejects dynamic or incompatible pinned mise versions", context do
    opts = runtime_opts(context)
    config = context.tool_config

    File.write!(config, "[tools]\nerlang = \"latest\"\nelixir = \"1.19.5-otp-28\"\n")

    assert {:error, {:invalid_host_resource_contract, %{resource: :erlang, reason: :dynamic_selector}}} =
             HostResourceContract.resolve(context.declaration, opts)

    File.write!(config, "[tools]\nerlang = \"27\"\nelixir = \"1.19.5-otp-28\"\n")

    assert {:error, {:invalid_host_resource_contract, %{resource: :erlang, reason: :version_mismatch}}} =
             HostResourceContract.resolve(context.declaration, opts)

    incompatible = put_in(context.declaration, ["operations", "symphony_runtime_verification", "erlang", "version"], "27.0")
    incompatible = put_in(incompatible, ["operations", "symphony_runtime_verification", "erlang", "install_path"], Path.join(Path.dirname(verification_install_path(context)), "27.0"))

    assert {:error, {:invalid_host_resource_contract, %{resource: :versions, reason: :incompatible}}} =
             HostResourceContract.resolve(incompatible, opts)
  end

  test "rejects unsupported DNS targets without reading arbitrary files", context do
    declaration = %{
      "schema_version" => 1,
      "role" => context.declaration["role"],
      "execution_generation" => context.declaration["execution_generation"],
      "runtime_generation" => context.declaration["runtime_generation"],
      "operations" => %{"host_dns" => %{"resolver_target" => Path.join(context.root, "resolv.conf")}}
    }

    assert {:error, {:invalid_host_resource_contract, %{resource: :resolver_target, reason: :unsupported_target}}} =
             HostResourceContract.resolve(declaration,
               role: "implementer",
               execution_generation: "exec-20260906",
               runtime_generation: 7
             )
  end

  test "bounds launcher symlink resolution and rejects symlinked installation roots", context do
    opts = runtime_opts(context)
    runtime_path = ["operations", "symphony_runtime_verification"]
    chain_root = Path.join(context.root, "mise-chain")
    File.mkdir_p!(chain_root)

    link_at = fn count ->
      Enum.reduce(Range.new(count, 1, -1), context.mise_target, fn index, next_target ->
        link = Path.join(chain_root, "link-#{index}")
        File.ln_s!(next_target, link)
        link
      end)
    end

    bounded = put_in(context.declaration, runtime_path ++ ["mise", "executable"], link_at.(16))

    assert {:ok, _contract} = HostResourceContract.resolve(bounded, opts)

    File.rm_rf!(chain_root)
    File.mkdir_p!(chain_root)
    excessive = put_in(context.declaration, runtime_path ++ ["mise", "executable"], link_at.(17))

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :symlink_hops_exceeded}}} =
             HostResourceContract.resolve(excessive, opts)

    File.rm_rf!(chain_root)
    File.mkdir_p!(chain_root)
    cycle_a = Path.join(chain_root, "cycle-a")
    cycle_b = Path.join(chain_root, "cycle-b")
    File.ln_s!(cycle_b, cycle_a)
    File.ln_s!(cycle_a, cycle_b)
    cyclic = put_in(context.declaration, runtime_path ++ ["mise", "executable"], cycle_a)

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :symlink_cycle}}} =
             HostResourceContract.resolve(cyclic, opts)

    install_path = context.declaration["operations"]["symphony_runtime_verification"]["elixir"]["install_path"]
    relocated = Path.join([context.root, "relocated", "installs", "elixir", Path.basename(install_path)])
    File.mkdir_p!(Path.dirname(relocated))
    File.rename!(install_path, relocated)
    File.ln_s!(relocated, install_path)

    assert {:error, {:invalid_host_resource_contract, %{resource: {:elixir, :install_path}, reason: :not_canonical}}} =
             HostResourceContract.resolve(context.declaration, opts)
  end

  test "rejects an exact launcher grant from a shims collection", context do
    shims_dir = Path.join(context.root, "shims")
    shim = Path.join(shims_dir, "mise")
    File.mkdir_p!(shims_dir)
    File.ln_s!(context.mise_target, shim)

    declaration =
      put_in(
        context.declaration,
        ["operations", "symphony_runtime_verification", "mise", "executable"],
        shim
      )

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :unsafe_root}}} =
             HostResourceContract.resolve(declaration, runtime_opts(context))

    refute inspect(HostResourceContract.resolve(declaration, runtime_opts(context))) =~ shim
  end

  test "rejects dangling launcher links and launcher target mismatches", context do
    links_dir = Path.join(context.root, "launcher-links")
    dangling = Path.join(links_dir, "dangling-mise")
    mismatched = Path.join(links_dir, "mismatched-mise")
    other_target = Path.join(context.root, "other-mise-target")
    File.mkdir_p!(links_dir)
    File.ln_s!(Path.join(context.root, "missing-mise-target"), dangling)
    File.write!(other_target, "#!/bin/sh\nexit 0\n")
    File.chmod!(other_target, 0o755)
    File.ln_s!(other_target, mismatched)

    runtime_path = ["operations", "symphony_runtime_verification", "mise", "executable"]

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :missing}}} =
             context.declaration
             |> put_in(runtime_path, dangling)
             |> HostResourceContract.resolve(runtime_opts(context))

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_executable, reason: :target_mismatch}}} =
             context.declaration
             |> put_in(runtime_path, mismatched)
             |> HostResourceContract.resolve(runtime_opts(context))
  end

  test "concurrent session resolutions retain distinct installed versions", context do
    other_root = Path.join(context.root, "other")
    other_tool_config = Path.join(other_root, "mise.toml")
    other_mise = Path.join([other_root, "mise", "bin", "mise"])
    other_target = Path.join([other_root, "mise", "targets", "mise-2026.10"])
    other_elixir = Path.join([other_root, "mise", "installs", "elixir", "1.18.4-otp-27"])
    other_erlang = Path.join([other_root, "mise", "installs", "erlang", "27.3"])

    File.mkdir_p!(Path.dirname(other_mise))
    File.mkdir_p!(Path.dirname(other_target))
    File.mkdir_p!(Path.join(other_elixir, "bin"))
    File.mkdir_p!(Path.join(other_erlang, "bin"))
    File.write!(other_tool_config, "[tools]\nerlang = \"27\"\nelixir = \"1.18.4-otp-27\"\n")
    File.write!(other_target, "#!/bin/sh\nexit 0\n")
    File.ln_s!(other_target, other_mise)
    File.write!(Path.join(other_elixir, "bin/elixir"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(other_erlang, "bin/erl"), "#!/bin/sh\nexit 0\n")
    File.chmod!(other_target, 0o755)
    File.chmod!(Path.join(other_elixir, "bin/elixir"), 0o755)
    File.chmod!(Path.join(other_erlang, "bin/erl"), 0o755)

    other_declaration =
      context.declaration
      |> put_in(["runtime_generation"], 8)
      |> put_in(["operations", "symphony_runtime_verification", "symphony_ref"], String.duplicate("b", 40))
      |> put_in(["operations", "symphony_runtime_verification", "tool_config"], other_tool_config)
      |> put_in(["operations", "symphony_runtime_verification", "tool_config_sha256"], digest(other_tool_config))
      |> put_in(["operations", "symphony_runtime_verification", "mise", "executable"], other_mise)
      |> put_in(["operations", "symphony_runtime_verification", "mise", "target"], other_target)
      |> put_in(["operations", "symphony_runtime_verification", "mise", "sha256"], digest(other_target))
      |> put_in(["operations", "symphony_runtime_verification", "elixir", "version"], "1.18.4-otp-27")
      |> put_in(["operations", "symphony_runtime_verification", "elixir", "install_path"], other_elixir)
      |> put_in(["operations", "symphony_runtime_verification", "erlang", "version"], "27.3")
      |> put_in(["operations", "symphony_runtime_verification", "erlang", "install_path"], other_erlang)

    other_opts = [
      role: "implementer",
      execution_generation: "exec-20260906",
      runtime_generation: 8,
      source_ref: String.duplicate("b", 40),
      tool_config_path: other_tool_config,
      tool_config_sha256: digest(other_tool_config)
    ]

    first = Task.async(fn -> HostResourceContract.resolve(context.declaration, runtime_opts(context)) end)
    second = Task.async(fn -> HostResourceContract.resolve(other_declaration, other_opts) end)

    assert {:ok, first_contract} = Task.await(first)
    assert {:ok, second_contract} = Task.await(second)
    assert first_contract.operations["symphony_runtime_verification"]["elixir"].version == "1.19.5-otp-28"
    assert second_contract.operations["symphony_runtime_verification"]["elixir"].version == "1.18.4-otp-27"
    assert first_contract.commands.elixir != second_contract.commands.elixir
    refute Enum.any?(first_contract.read_paths, &String.starts_with?(&1, other_root <> "/"))
    refute Enum.any?(second_contract.read_paths, &String.starts_with?(&1, Path.join(context.root, "mise") <> "/"))
  end

  test "a later session revalidates changed host resources", context do
    assert {:ok, first_contract} =
             HostResourceContract.resolve(context.declaration, runtime_opts(context))

    File.write!(context.mise_target, "#!/bin/sh\nexit 1\n")
    File.chmod!(context.mise_target, 0o755)

    assert {:error, {:invalid_host_resource_contract, %{resource: :mise_sha256, reason: :digest_mismatch}}} =
             HostResourceContract.resolve(context.declaration, runtime_opts(context))

    assert first_contract.provenance.mise_sha256 ==
             context.declaration["operations"]["symphony_runtime_verification"]["mise"]["sha256"]
  end

  defp digest(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp runtime_opts(context) do
    verification = context.declaration["operations"]["symphony_runtime_verification"]

    [
      role: "implementer",
      execution_generation: "exec-20260906",
      runtime_generation: 7,
      source_ref: verification["symphony_ref"],
      tool_config_path: context.tool_config,
      tool_config_sha256: verification["tool_config_sha256"]
    ]
  end

  defp verification_install_path(context) do
    context.declaration["operations"]["symphony_runtime_verification"]["erlang"]["install_path"]
  end
end
