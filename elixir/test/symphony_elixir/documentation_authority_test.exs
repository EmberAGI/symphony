defmodule SymphonyElixir.DocumentationAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DocumentationAuthority

  test "canonical fixture repository reports no errors or warnings" do
    root = build_canonical_fixture()

    assert DocumentationAuthority.inspect_repository(root) == %{errors: [], warnings: []}
    assert DocumentationAuthority.validate!(root) == {:ok, []}
  end

  test "the real repository root passes validation" do
    root = repo_root()

    assert {:ok, _warnings} = DocumentationAuthority.validate!(root)
  end

  test "missing hierarchy reports errors for each absent canonical path" do
    root = create_tmp_dir()

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "docs/specs/index.md"))
    assert Enum.any?(result.errors, &String.contains?(&1, "docs/specs/domains"))
    assert Enum.any?(result.errors, &String.contains?(&1, "docs/adr"))

    assert_raise RuntimeError, fn -> DocumentationAuthority.validate!(root) end
  end

  test "legacy-only hierarchy is rejected" do
    root = create_tmp_dir()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, [legacy_segment, "index.md"], "# Legacy index\n")
    write_file(root, [legacy_segment, "domains", "sample.md"], "# Sample\n")
    write_file(root, [legacy_segment, "adr", "0001-sample.md"], "# ADR\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "legacy documentation authority hierarchy"))
    assert Enum.any?(result.errors, &String.contains?(&1, "docs/specs/index.md"))
  end

  test "a legacy hierarchy alongside the canonical one is rejected as a duplicate authority" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pecs"], "")

    write_file(root, [legacy_segment, "index.md"], "# Duplicate index\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "legacy documentation authority hierarchy"))
  end

  test "a symlinked canonical directory is rejected as an alias" do
    root = build_canonical_fixture()

    real_domains = Path.join([root, "docs", "specs", "domains"])
    alias_target = Path.join([root, "docs", "specs", "domains-alias"])
    File.rename!(real_domains, alias_target)
    File.ln_s!(alias_target, real_domains)

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "docs/specs/domains is a symlink"))
  end

  test "a symlinked canonical file is rejected as an alias" do
    root = build_canonical_fixture()

    real_index = Path.join([root, "docs", "specs", "index.md"])
    alias_target = Path.join([root, "docs", "specs", "index-alias.md"])
    File.rename!(real_index, alias_target)
    File.ln_s!(alias_target, real_index)

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "docs/specs/index.md is a symlink"))
  end

  test "stale active references to a legacy authority path are rejected" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["README.md"], "See #{legacy_segment}/domains/thing.md for details.\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "stale legacy documentation authority path"))
    assert Enum.any?(result.errors, &String.contains?(&1, "README.md:1"))
  end

  test "a stale relative link to a legacy authority path is rejected" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["elixir", "README.md"], "Start with [the index](../#{legacy_segment}/index.md).\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "stale legacy documentation authority path"))
  end

  test "a relative plural legacy path outside the canonical hierarchy is rejected" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pecs"], "")

    write_file(root, ["elixir", "README.md"], "Start with [the index](../#{legacy_segment}/index.md).\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "stale legacy documentation authority path"))
    assert Enum.any?(result.errors, &String.contains?(&1, "elixir/README.md:1"))
  end

  test "a relative plural path resolving into the canonical hierarchy is accepted" do
    root = build_canonical_fixture()
    canonical_segment = Enum.join(["s", "pecs"], "")

    write_file(root, ["docs", "adr", "0002-linking.md"], """
    See [the specification](../#{canonical_segment}/domains/sample.md).
    """)

    result = DocumentationAuthority.inspect_repository(root)

    refute Enum.any?(result.errors, &String.contains?(&1, "stale legacy documentation authority path"))
  end

  test "a stale-looking reference is allowed when the line names the upstream repository" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")
    upstream = Enum.join(["scaling", "-", "octo", "-", "engine"], "")

    write_file(root, ["README.md"], "The #{upstream} repository still uses #{legacy_segment}/domains/thing.md.\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert result.errors == []
  end

  test "an untracked stale reference in a git work tree is not an active surface" do
    root = build_canonical_fixture()
    git_init_and_commit!(root)
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["SCRATCH.md"], "See #{legacy_segment}/domains/thing.md for details.\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert result.errors == []
  end

  test "a tracked stale reference in a git work tree is rejected" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["README.md"], "See #{legacy_segment}/domains/thing.md for details.\n")
    git_init_and_commit!(root)

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "stale legacy documentation authority path"))
    assert Enum.any?(result.errors, &String.contains?(&1, "README.md:1"))
  end

  test "stale references in TOML and JSON metadata files are rejected" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["contract.toml"], ~s(contract_ref = "#{legacy_segment}/domains/thing.md"\n))
    write_file(root, ["metadata.json"], ~s({"path": "#{legacy_segment}/domains/thing.md"}\n))

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "contract.toml:1"))
    assert Enum.any?(result.errors, &String.contains?(&1, "metadata.json:1"))
  end

  test "a relative link that escapes the repository root is rejected even when the target exists" do
    root = build_canonical_fixture()

    outside_target = Path.join(Path.dirname(root), "#{Path.basename(root)}-escape-target.md")
    File.write!(outside_target, "# Outside\n")
    on_exit(fn -> File.rm_rf!(outside_target) end)

    write_file(root, ["docs", "specs", "domains", "escaping.md"], """
    See [outside](../../../../#{Path.basename(outside_target)}) for details.
    """)

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "escapes the repository"))
  end

  test "a relative link that escapes through an in-repository symlink is rejected" do
    root = build_canonical_fixture()
    outside_dir = create_tmp_dir()

    write_file(outside_dir, ["outside.md"], "# Outside\n")
    File.ln_s!(outside_dir, Path.join(root, "linked-outside"))

    write_file(root, ["docs", "specs", "domains", "escaping-via-symlink.md"], """
    See [outside](../../../linked-outside/outside.md) for details.
    """)

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "escapes the repository"))
  end

  test "a nested spec directory outside the canonical hierarchy produces a warning" do
    root = build_canonical_fixture()
    legacy_segment = Enum.join(["s", "pec"], "")

    write_file(root, ["elixir", legacy_segment, "sample.md"], "# Sample\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert result.errors == []
    assert Enum.any?(result.warnings, &String.contains?(&1, Path.join(["elixir", legacy_segment])))
  end

  test "a broken relative link inside a canonical document is rejected" do
    root = build_canonical_fixture()

    write_file(root, ["docs", "specs", "domains", "broken.md"], "See [missing](./nowhere.md) for details.\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert Enum.any?(result.errors, &String.contains?(&1, "broken relative link"))
    assert Enum.any?(result.errors, &String.contains?(&1, "nowhere.md"))
  end

  test "relative links that resolve, plus http/mailto/anchor/absolute links, are accepted" do
    root = build_canonical_fixture()

    write_file(root, ["docs", "specs", "domains", "other.md"], "# Other\n")

    write_file(root, ["docs", "specs", "domains", "linking.md"], """
    # Linking

    - [sibling](./other.md)
    - [external](https://example.com/thing)
    - [mail](mailto:someone@example.com)
    - [anchor](#section)
    - [absolute](/etc/hosts)
    """)

    result = DocumentationAuthority.inspect_repository(root)

    assert result.errors == []
  end

  test "nonstandard spec-like files and directories outside the canonical hierarchy produce warnings" do
    root = build_canonical_fixture()

    write_file(root, ["lib", "widgets", "widget.spec.html"], "<html></html>\n")
    write_file(root, ["lib", "widgets", "adr", "note.md"], "# Note\n")

    result = DocumentationAuthority.inspect_repository(root)

    assert result.errors == []
    assert Enum.any?(result.warnings, &String.contains?(&1, "widget.spec.html"))
    assert Enum.any?(result.warnings, &String.contains?(&1, Path.join(["lib", "widgets", "adr"])))
  end

  test "a visual specification in the canonical ADR hierarchy does not produce a warning" do
    root = build_canonical_fixture()

    write_file(root, ["docs", "adr", "architecture.spec.html"], "<html></html>\n")

    result = DocumentationAuthority.inspect_repository(root)

    refute Enum.any?(result.warnings, &String.contains?(&1, "architecture.spec.html"))
  end

  defp build_canonical_fixture do
    root = create_tmp_dir()

    write_file(root, ["docs", "specs", "index.md"], "# Spec Index\n")
    write_file(root, ["docs", "specs", "domains", "sample.md"], "# Sample\n")
    write_file(root, ["docs", "adr", "0001-sample.md"], "# ADR\n")

    root
  end

  defp repo_root do
    Path.expand(Path.join([File.cwd!(), ".."]))
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "documentation-authority-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git_init_and_commit!(root) do
    git!(root, ["init", "-q"])
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=fixture",
      "-c",
      "user.email=fixture@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "fixture"
    ])
  end

  defp git!(root, args) do
    {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  defp write_file(root, segments, content) do
    path = Path.join([root | segments])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
