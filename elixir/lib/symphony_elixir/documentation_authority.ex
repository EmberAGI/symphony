defmodule SymphonyElixir.DocumentationAuthority do
  @moduledoc """
  Enforces the canonical documentation authority contract described in
  `docs/specs/domains/documentation-authority.md` and
  `docs/adr/0003-canonical-documentation-authority.md`: the only durable
  specification and architecture-decision authority in this repository lives
  under `docs/specs/` and `docs/adr/`.
  """

  @type inspection :: %{errors: [String.t()], warnings: [String.t()]}

  @scanned_extensions ~w(.md .ex .exs .toml .json .yml .yaml)
  @excluded_dirs ~w(_build deps .git .symphony node_modules)
  @legacy_top_level ~w(spec specs)
  @upstream_marker "scaling-octo-engine"

  @spec inspect_repository(Path.t()) :: inspection()
  def inspect_repository(root) do
    errors =
      hierarchy_errors(root) ++
        legacy_top_level_errors(root) ++
        symlink_errors(root) ++
        stale_reference_errors(root) ++
        broken_link_errors(root)

    %{errors: errors, warnings: nonstandard_path_warnings(root)}
  end

  @spec validate!(Path.t()) :: {:ok, [String.t()]}
  def validate!(root) do
    case inspect_repository(root) do
      %{errors: [], warnings: warnings} ->
        {:ok, warnings}

      %{errors: errors} ->
        raise "Documentation authority validation failed:\n" <> Enum.join(errors, "\n")
    end
  end

  defp hierarchy_errors(root) do
    index_path = Path.join([root, "docs", "specs", "index.md"])
    domains_dir = Path.join([root, "docs", "specs", "domains"])
    adr_dir = Path.join([root, "docs", "adr"])

    []
    |> check_regular_file(index_path, "docs/specs/index.md")
    |> check_nonempty_directory(domains_dir, "docs/specs/domains")
    |> check_nonempty_directory(adr_dir, "docs/adr")
  end

  defp check_regular_file(errors, path, label) do
    if File.regular?(path) do
      errors
    else
      ["#{label} is missing or is not a regular file" | errors]
    end
  end

  defp check_nonempty_directory(errors, path, label) do
    cond do
      not File.dir?(path) ->
        ["#{label} is missing or is not a directory" | errors]

      File.ls!(path) == [] ->
        ["#{label} is empty" | errors]

      true ->
        errors
    end
  end

  defp legacy_top_level_errors(root) do
    for name <- @legacy_top_level,
        path = Path.join(root, name),
        exists?(path) do
      "top-level #{name}/ directory is a legacy documentation authority hierarchy and is not permitted"
    end
  end

  defp exists?(path) do
    match?({:ok, _}, File.lstat(path))
  end

  defp symlink_errors(root) do
    canonical_paths = [Path.join([root, "docs", "specs"]), Path.join([root, "docs", "adr"])]

    physical_canonical_paths =
      Enum.flat_map(canonical_paths, fn path ->
        case resolve_physical_path(path) do
          {:ok, resolved} -> [resolved]
          {:error, _reason} -> []
        end
      end)

    root
    |> repository_symlinks()
    |> Enum.flat_map(fn path ->
      cond do
        overlaps_any?(path, canonical_paths) ->
          [
            "#{relative_path(path, root)} is a symlink, which is not permitted for canonical documentation authority"
          ]

        resolves_into_any?(path, physical_canonical_paths) ->
          [
            "#{relative_path(path, root)} aliases canonical documentation authority, which is not permitted"
          ]

        true ->
          []
      end
    end)
  end

  defp resolves_into_any?(path, canonical_paths) do
    case resolve_physical_path(path) do
      {:ok, resolved} -> overlaps_any?(resolved, canonical_paths)
      {:error, _reason} -> false
    end
  end

  defp repository_symlinks(root) do
    root
    |> walk_directories()
    |> Enum.flat_map(fn dir ->
      dir
      |> File.ls!()
      |> Enum.map(&Path.join(dir, &1))
    end)
    |> Enum.filter(&symlink?/1)
  end

  defp overlaps_any?(path, canonical_paths) do
    Enum.any?(canonical_paths, fn canonical_path ->
      inside_root?(path, canonical_path) or inside_root?(canonical_path, path)
    end)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp stale_reference_errors(root) do
    root
    |> scanned_files()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _line_number} -> stale_reference_line?(line, file, root) end)
      |> Enum.map(fn {_line, line_number} ->
        "#{relative_path(file, root)}:#{line_number} references a stale legacy documentation authority path"
      end)
    end)
  end

  defp stale_reference_line?(line, source_file, root) do
    legacy_path_reference?(line, source_file, root) and
      not String.contains?(line, @upstream_marker)
  end

  # Canonical paths never use a singular spec segment, so one is always a
  # legacy reference. Plural segments require source context: repository paths
  # resolve from the root, while explicit relative paths resolve from the
  # referencing file.
  @legacy_singular_regex ~r/(?<![\w-])spec\//
  @plural_path_regex ~r/(?<![\w-])((?:(?:\.\.?|[\w.-]+)\/)*specs\/)/

  defp legacy_path_reference?(line, source_file, root) do
    Regex.match?(@legacy_singular_regex, line) or
      Enum.any?(Regex.scan(@plural_path_regex, line, capture: :all_but_first), fn [reference] ->
        plural_reference_is_legacy?(reference, source_file, root)
      end)
  end

  defp plural_reference_is_legacy?(reference, source_file, root) do
    base =
      if String.starts_with?(reference, ["./", "../"]) do
        Path.dirname(source_file)
      else
        root
      end

    resolved = Path.expand(reference, base)
    not inside_root?(resolved, Path.join([root, "docs", "specs"]))
  end

  defp broken_link_errors(root) do
    canonical_doc_dirs = [Path.join([root, "docs", "specs"]), Path.join([root, "docs", "adr"])]

    canonical_doc_dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.md")))
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> extract_link_targets()
      |> Enum.reject(&skip_link_target?/1)
      |> Enum.flat_map(fn target -> link_target_errors(target, file, root) end)
    end)
  end

  @link_regex ~r/\]\(([^)]+)\)/

  defp extract_link_targets(content) do
    @link_regex
    |> Regex.scan(content)
    |> Enum.map(fn [_, target] -> target end)
  end

  defp skip_link_target?(target) do
    String.starts_with?(target, "http://") or
      String.starts_with?(target, "https://") or
      String.starts_with?(target, "mailto:") or
      String.starts_with?(target, "#") or
      String.starts_with?(target, "/")
  end

  defp link_target_errors(target, source_file, root) do
    case target |> String.split("#", parts: 2) |> List.first() do
      "" -> []
      path -> resolved_link_errors(path, target, source_file, root)
    end
  end

  defp resolved_link_errors(path, target, source_file, root) do
    resolved =
      source_file
      |> Path.dirname()
      |> Path.join(path)
      |> Path.expand()

    cond do
      not inside_root?(resolved, root) ->
        ["#{relative_path(source_file, root)} has a relative link to #{target} that escapes the repository"]

      not File.exists?(resolved) ->
        ["#{relative_path(source_file, root)} has a broken relative link to #{target}"]

      not physically_inside_root?(resolved, root) ->
        ["#{relative_path(source_file, root)} has a relative link to #{target} that escapes the repository"]

      true ->
        []
    end
  end

  defp inside_root?(path, root) do
    expanded_root = Path.expand(root)
    path == expanded_root or String.starts_with?(path, expanded_root <> "/")
  end

  defp physically_inside_root?(path, root) do
    with {:ok, physical_path} <- resolve_physical_path(path),
         {:ok, physical_root} <- resolve_physical_path(root) do
      inside_root?(physical_path, physical_root)
    else
      _ -> false
    end
  end

  defp resolve_physical_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reject(&(&1 == "/"))
    |> resolve_physical_segments("/", 0)
  end

  defp resolve_physical_segments([], resolved, _symlink_hops), do: {:ok, resolved}

  defp resolve_physical_segments([segment | rest], resolved, symlink_hops) do
    candidate = Path.join(resolved, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(candidate, rest, symlink_hops)

      {:ok, _stat} ->
        resolve_physical_segments(rest, candidate, symlink_hops)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(_candidate, _rest, symlink_hops) when symlink_hops >= 64 do
    {:error, :eloop}
  end

  defp resolve_symlink(candidate, rest, symlink_hops) do
    with {:ok, target} <- File.read_link(candidate) do
      target_segments =
        target
        |> Path.expand(Path.dirname(candidate))
        |> Path.split()
        |> Enum.reject(&(&1 == "/"))

      resolve_physical_segments(
        target_segments ++ rest,
        "/",
        symlink_hops + 1
      )
    end
  end

  defp nonstandard_path_warnings(root) do
    standard_dirs = [Path.join([root, "docs", "specs"]), Path.join([root, "docs", "adr"])]

    root
    |> walk_directories()
    |> Enum.reject(fn path -> under_any?(path, standard_dirs) end)
    |> Enum.flat_map(fn path -> nonstandard_entries(path, root, standard_dirs) end)
  end

  defp nonstandard_entries(dir, root, standard_dirs) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        path in standard_dirs ->
          []

        File.regular?(path) and String.ends_with?(entry, ".spec.html") ->
          ["nonstandard spec-like file: #{relative_path(path, root)}"]

        File.dir?(path) and entry in ~w(adr spec specs) and Path.dirname(path) != root ->
          ["nonstandard #{entry} directory outside the canonical hierarchy: #{relative_path(path, root)}"]

        true ->
          []
      end
    end)
  end

  defp under_any?(path, dirs) do
    Enum.any?(dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp walk_directories(root) do
    [root | do_walk_directories(root)]
  end

  defp do_walk_directories(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      if excluded?(entry) or symlink?(path) or not File.dir?(path) do
        []
      else
        [path | do_walk_directories(path)]
      end
    end)
  end

  defp excluded?(entry), do: entry in @excluded_dirs

  # Stale-reference scanning covers only active surfaces: inside a Git work
  # tree that is the tracked file set; outside one (bounded fixture roots)
  # the directory walk stands in for it.
  defp scanned_files(root) do
    root
    |> active_files()
    |> Enum.filter(fn path -> File.regular?(path) and not symlink?(path) and scanned_extension?(path) end)
  end

  defp active_files(root) do
    case tracked_files(root) do
      {:ok, files} -> files
      :error -> walked_files(root)
    end
  end

  defp tracked_files(root) do
    with true <- exists?(Path.join(root, ".git")),
         {listing, 0} <- System.cmd("git", ["-C", root, "ls-files", "-z"], stderr_to_stdout: true) do
      {:ok, listing |> String.split(<<0>>, trim: true) |> Enum.map(&Path.join(root, &1))}
    else
      _ -> :error
    end
  end

  defp walked_files(root) do
    root
    |> walk_directories()
    |> Enum.flat_map(fn dir ->
      dir
      |> File.ls!()
      |> Enum.map(&Path.join(dir, &1))
    end)
  end

  defp scanned_extension?(path), do: Path.extname(path) in @scanned_extensions

  defp relative_path(path, root) do
    Path.relative_to(path, root)
  end
end
