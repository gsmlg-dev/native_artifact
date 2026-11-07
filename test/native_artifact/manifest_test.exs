defmodule NativeArtifact.ManifestTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Error, Manifest}

  @fixture_path Path.expand("../fixtures/manifest-v1.json", __DIR__)

  setup_all do
    json = File.read!(@fixture_path)
    {:ok, json: json, fixture: JSON.decode!(json)}
  end

  test "accepts the illustrative fixture as metadata without changing its data", ctx do
    assert {:ok, %{__struct__: Manifest, data: data}} = Manifest.decode(ctx.json)
    assert data === ctx.fixture
    assert {:ok, %{__struct__: Manifest, data: ^data}} = Manifest.validate(ctx.fixture)
  end

  test "rejects duplicate object keys, including escaped and nested aliases", ctx do
    for json <- [
          ~s({"schema_version":1,"schema_version":1}),
          ~s({"schema_version":1,"schema_versio\\u006e":1}),
          String.replace(
            ctx.json,
            ~s("non_production": true),
            ~s("non_production": true, "non_production": false)
          )
        ] do
      assert {:error, %Error{code: :invalid_manifest, details: %{reason: :duplicate_json_key}}} =
               Manifest.decode(json)
    end
  end

  test "rejects malformed, trailing and non-object JSON without leaking input" do
    for json <- ["{", "{}{}", "{} secret-token", "[1]", "null", <<255>>] do
      assert {:error, %Error{code: :invalid_manifest} = error} = Manifest.decode(json)
      refute inspect(error) =~ "secret-token"
    end
  end

  test "classifies unsupported schema, kind and required behavior", %{fixture: data} do
    assert_invalid(put_in(data, ["schema_version"], 2), :unsupported_schema)

    data
    |> put_in(["artifacts", Access.at(0), "kind"], "cli")
    |> assert_invalid(:unsupported_artifact_kind)

    assert_invalid(put_in(data, ["required_features"], ["future-secret"]), :unsupported_schema)
  end

  test "requires core fields and rejects unknown properties at every object boundary", %{
    fixture: data
  } do
    boundaries = [
      {[], "package"},
      {artifact_path(), "native_version"},
      {artifact_path() ++ ["target"], "endianness"},
      {artifact_path() ++ ["compatibility"], "min_os_version"},
      {artifact_path() ++ ["compatibility", "nif"], "minor"},
      {artifact_path() ++ ["compatibility", "system_libraries", Access.at(0)], "name"},
      {artifact_path() ++ ["binding"], "fingerprint"},
      {artifact_path() ++ ["sources", Access.at(0)], "url"},
      {artifact_path() ++ ["sources", Access.at(1)], "path"},
      {artifact_path() ++ ["archive"], "size"},
      {artifact_path() ++ ["files", Access.at(0)], "mode"},
      {artifact_path() ++ ["licenses", Access.at(0)], "spdx"},
      {artifact_path() ++ ["provenance"], "lockfile_sha256"},
      {artifact_path() ++ ["provenance", "toolchains", Access.at(0)], "version"},
      {artifact_path() ++ ["provenance", "nif_headers_version"], "major"}
    ]

    for {path, field} <- boundaries do
      assert_invalid(update_at(data, path, &Map.delete(&1, field)))

      details =
        assert_invalid(update_at(data, path, &Map.put(&1, "secret-extra-key", "secret-value")))

      refute inspect(details) =~ "secret"
    end
  end

  test "enforces identity, scalar, array and nested-field types", %{fixture: data} do
    invalid_fields = [
      {["package"], "UpperCase"},
      {["package_version"], "0.1"},
      {["required_features"], nil},
      {["artifacts"], []},
      {["artifacts"], %{}},
      {artifact_path() ++ ["id"], "Bad ID"},
      {artifact_path() ++ ["native_version"], ""},
      {artifact_path() ++ ["build_revision"], 0},
      {artifact_path() ++ ["build_revision"], 1.5},
      {artifact_path() ++ ["target"], nil},
      {artifact_path() ++ ["target", "pointer_width"], 32},
      {artifact_path() ++ ["target", "endianness"], "big"},
      {artifact_path() ++ ["compatibility", "nif", "major"], 0},
      {artifact_path() ++ ["compatibility", "nif", "minor"], -1},
      {artifact_path() ++ ["compatibility", "min_erts"], "15"},
      {artifact_path() ++ ["compatibility", "min_os_version"], "6"},
      {artifact_path() ++ ["compatibility", "vm_variant"], "jit"},
      {artifact_path() ++ ["compatibility", "system_libraries"], %{}},
      {artifact_path() ++ ["compatibility", "system_libraries", Access.at(0), "name"], ""},
      {artifact_path() ++ ["binding", "module"], "Elixir.bad"},
      {artifact_path() ++ ["binding", "interface_version"], ""},
      {artifact_path() ++ ["binding", "fingerprint"], String.duplicate("A", 64)},
      {artifact_path() ++ ["sources"], []},
      {artifact_path() ++ ["archive", "filename"], "../codec.tar.gz"},
      {artifact_path() ++ ["archive", "format"], "zip"},
      {artifact_path() ++ ["archive", "size"], 0},
      {artifact_path() ++ ["archive", "sha256"], "abcd"},
      {artifact_path() ++ ["files"], []},
      {artifact_path() ++ ["files", Access.at(0), "type"], "symlink"},
      {artifact_path() ++ ["files", Access.at(0), "role"], "executable"},
      {artifact_path() ++ ["files", Access.at(0), "size"], -1},
      {artifact_path() ++ ["files", Access.at(0), "sha256"], nil},
      {artifact_path() ++ ["files", Access.at(0), "mode"], "0777"},
      {artifact_path() ++ ["licenses"], []},
      {artifact_path() ++ ["licenses", Access.at(0), "spdx"], ""},
      {artifact_path() ++ ["provenance", "source_commit"], "main"},
      {artifact_path() ++ ["provenance", "toolchains"], []},
      {artifact_path() ++ ["provenance", "toolchains", Access.at(0), "name"], ""},
      {artifact_path() ++ ["provenance", "toolchains", Access.at(0), "version"], nil},
      {artifact_path() ++ ["provenance", "parameters"], [1]},
      {artifact_path() ++ ["provenance", "nif_headers_version", "minor"], "17"},
      {artifact_path() ++ ["provenance", "sysroot_sha256"], "sha256:bad"}
    ]

    for {path, value} <- invalid_fields do
      assert_invalid(put_in(data, path, value))
    end
  end

  test "supports all six explicit platform descriptions and nullable Linux kernel policy", %{
    fixture: data
  } do
    for os <- ["linux", "macos"],
        arch <- ["x86_64", "aarch64"],
        libc <- if(os == "linux", do: ["glibc", "musl"], else: ["none"]) do
      candidate =
        data
        |> put_in(artifact_path() ++ ["target"], %{
          "os" => os,
          "arch" => arch,
          "libc" => libc,
          "object_format" => if(os == "linux", do: "elf", else: "mach-o"),
          "pointer_width" => 64,
          "endianness" => "little",
          "cpu_baseline" => if(arch == "x86_64", do: "x86-64", else: "armv8-a")
        })
        |> put_in(
          artifact_path() ++ ["compatibility", "min_libc_version"],
          if(os == "linux", do: "1.2.5", else: nil)
        )
        |> put_in(
          artifact_path() ++ ["compatibility", "min_os_version"],
          if(os == "linux", do: nil, else: "13.0")
        )

      assert {:ok, _manifest} = Manifest.validate(candidate)

      if os == "macos" do
        assert_invalid(
          put_in(candidate, artifact_path() ++ ["compatibility", "min_os_version"], nil)
        )

        assert_invalid(
          put_in(candidate, artifact_path() ++ ["compatibility", "min_libc_version"], "2.28")
        )
      else
        assert {:ok, _manifest} =
                 Manifest.validate(
                   put_in(
                     candidate,
                     artifact_path() ++ ["compatibility", "min_os_version"],
                     "6.1"
                   )
                 )

        assert_invalid(
          put_in(candidate, artifact_path() ++ ["compatibility", "min_libc_version"], nil)
        )
      end
    end

    for {field, value} <- [
          {"libc", "none"},
          {"object_format", "mach-o"},
          {"cpu_baseline", "armv8-a"},
          {"os", "windows"},
          {"arch", "riscv64"}
        ] do
      assert_invalid(put_in(data, artifact_path() ++ ["target", field], value))
    end
  end

  test "accepts JSON Schema integer-valued numbers and preserves optional provenance", %{
    fixture: data
  } do
    candidate =
      data
      |> put_in(["schema_version"], 1.0)
      |> put_in(artifact_path() ++ ["build_revision"], 1.0)
      |> put_in(artifact_path() ++ ["target", "pointer_width"], 64.0)
      |> put_in(artifact_path() ++ ["files", Access.at(0), "size"], 512.0)
      |> put_in(artifact_path() ++ ["provenance", "source_commit"], String.duplicate("a", 64))
      |> put_in(artifact_path() ++ ["provenance", "parameters"], [""])
      |> put_in(artifact_path() ++ ["provenance", "lockfile_sha256"], String.duplicate("b", 64))

    assert {:ok, %{data: ^candidate}} = Manifest.validate(candidate)
    assert {:ok, %{data: ^candidate}} = Manifest.decode(JSON.encode!(candidate))
  end

  test "requires stable HTTPS or safe package-relative local sources", %{fixture: data} do
    for url <- [
          "http://example.invalid/a",
          "https://user:secret@example.invalid/a",
          "https://example.invalid/a?token=secret",
          "https://example.invalid/a#secret",
          "https://example.invalid/a b"
        ] do
      details =
        assert_invalid(put_in(data, artifact_path() ++ ["sources", Access.at(0), "url"], url))

      refute inspect(details) =~ "secret"
      assert_invalid(put_in(data, artifact_path() ++ ["provenance", "source_repository"], url))
    end

    for source <- [
          %{"type" => "ftp", "url" => "ftp://example.invalid/a"},
          %{"type" => "https", "url" => "https://example.invalid/a", "path" => "a"},
          %{"type" => "local", "url" => "https://example.invalid/a"}
        ] do
      assert_invalid(put_in(data, artifact_path() ++ ["sources", Access.at(0)], source))
    end
  end

  test "rejects unsafe paths at every path-bearing location", %{fixture: data} do
    paths = [
      artifact_path() ++ ["entrypoint"],
      artifact_path() ++ ["private_libraries", Access.at(0)],
      artifact_path() ++ ["files", Access.at(0), "path"],
      artifact_path() ++ ["licenses", Access.at(0), "file"],
      artifact_path() ++ ["sources", Access.at(1), "path"]
    ]

    values = [
      "",
      "/tmp/nif.so",
      "C:relative.so",
      "C:/nif.so",
      "lib\\nif.so",
      "../nif.so",
      "lib/./nif.so",
      "lib/../nif.so",
      "lib//nif.so",
      "lib/",
      "a\0b",
      "a\nb",
      "a\x7fb",
      String.duplicate("a", 4097),
      String.duplicate("a\u0301", 2049)
    ]

    for path <- paths, value <- values, do: assert_invalid(put_in(data, path, value))

    assert {:ok, _manifest} =
             Manifest.validate(
               put_in(
                 data,
                 artifact_path() ++ ["sources", Access.at(1), "path"],
                 String.duplicate("é", 4096)
               )
             )
  end

  test "checks unique items in nested contract lists", %{fixture: data} do
    for path <- [
          artifact_path() ++ ["sources"],
          artifact_path() ++ ["private_libraries"],
          artifact_path() ++ ["files"],
          artifact_path() ++ ["licenses"],
          artifact_path() ++ ["compatibility", "system_libraries"],
          artifact_path() ++
            ["compatibility", "system_libraries", Access.at(0), "symbol_versions"]
        ] do
      assert_invalid(update_in(data, path, &(&1 ++ [hd(&1)])))
    end

    symbols_path =
      artifact_path() ++ ["compatibility", "system_libraries", Access.at(0), "required_symbols"]

    assert_invalid(put_in(data, symbols_path, ["malloc", "malloc"]))
    assert_invalid(put_in(data, symbols_path, [""]))

    [first | _] = get_in(data, artifact_path() ++ ["files"])
    numeric_duplicate = Map.put(first, "size", first["size"] * 1.0)

    assert %{reason: :duplicate_item} =
             assert_invalid(
               put_in(data, artifact_path() ++ ["files"], [first, numeric_duplicate])
             )
  end

  test "requires unique artifact identities and file paths independently of contents", %{
    fixture: data
  } do
    [artifact] = data["artifacts"]

    assert %{reason: :duplicate_artifact_id} =
             assert_invalid(%{data | "artifacts" => [artifact, artifact]})

    [first | _] = artifact["files"]
    conflicting = Map.put(first, "size", first["size"] + 1)

    assert %{reason: :duplicate_file_path} =
             assert_invalid(update_in(data, artifact_path() ++ ["files"], &(&1 ++ [conflicting])))
  end

  test "rejects file/directory collisions before extraction", %{fixture: data} do
    [file | _] = get_in(data, artifact_path() ++ ["files"])
    collision = %{file | "path" => "lib", "role" => "data"}
    unrelated = %{file | "path" => "lib-elsewhere", "role" => "metadata"}

    assert %{reason: :file_directory_conflict} =
             assert_invalid(
               update_in(data, artifact_path() ++ ["files"], &(&1 ++ [collision, unrelated]))
             )
  end

  test "requires exactly one owned NIF entrypoint", %{fixture: data} do
    assert_invalid(put_in(data, artifact_path() ++ ["entrypoint"], "LICENSE"))
    assert_invalid(put_in(data, artifact_path() ++ ["files", Access.at(0), "role"], "data"))
    assert_invalid(put_in(data, artifact_path() ++ ["files", Access.at(1), "role"], "nif"))
  end

  test "private libraries and licenses must exactly cover their owned file roles", %{
    fixture: data
  } do
    for refs <- [[], ["LICENSE"], ["missing.so"]],
        do: assert_invalid(put_in(data, artifact_path() ++ ["private_libraries"], refs))

    assert_invalid(put_in(data, artifact_path() ++ ["files", Access.at(1), "role"], "data"))

    for file <- ["missing", "lib/codec.so"],
        do:
          assert_invalid(
            put_in(data, artifact_path() ++ ["licenses", Access.at(0), "file"], file)
          )

    assert_invalid(put_in(data, artifact_path() ++ ["files", Access.at(2), "role"], "data"))

    license = get_in(data, artifact_path() ++ ["files", Access.at(2)])

    assert_invalid(
      update_in(data, artifact_path() ++ ["files"], &(&1 ++ [%{license | "path" => "NOTICE"}]))
    )

    # Multiple SPDX identities may intentionally cite the same owned license file.
    candidate =
      update_in(
        data,
        artifact_path() ++ ["licenses"],
        &(&1 ++ [%{"spdx" => "Apache-2.0", "file" => "LICENSE"}])
      )

    assert {:ok, _manifest} = Manifest.validate(candidate)
  end

  test "extensions carry JSON data under namespaced keys without creating atoms", %{fixture: data} do
    module = "Elixir.UninternedManifest#{System.unique_integer([:positive])}.Native"
    key = "vendor:uninterned#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(module) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    candidate =
      data
      |> put_in(artifact_path() ++ ["binding", "module"], module)
      |> put_in(["extensions"], %{
        key => [nil, true, false, 0, -2, 1.25, "λ\n\"\\", %{"anything" => "descriptive"}]
      })
      |> put_in(artifact_path() ++ ["extensions"], %{"vendor:annotation" => %{}})

    assert {:ok, %{data: ^candidate}} = Manifest.decode(JSON.encode!(candidate))
    assert_raise ArgumentError, fn -> String.to_existing_atom(module) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    for extensions <- [[], %{"unscoped" => true}, %{"Vendor:value" => true}],
        do: assert_invalid(put_in(data, ["extensions"], extensions))
  end

  test "rejects non-JSON decoded terms instead of raising", %{fixture: data} do
    for value <- [
          :atom,
          self(),
          make_ref(),
          fn -> :ok end,
          {:tuple, 1},
          %{atom_key: true},
          ["value" | :improper],
          <<255>>,
          <<1::1>>
        ] do
      assert_invalid(put_in(data, ["extensions"], %{"vendor:value" => value}))
    end

    for value <- [nil, [], 1, true, "json", %URI{}], do: assert_invalid(value)
    assert {:error, %Error{code: :invalid_manifest}} = Manifest.decode(nil)
  end

  test "bounds original and compact metadata bytes including escaped strings", %{fixture: data} do
    candidate = put_in(data, ["extensions"], %{"vendor:bytes" => "\0\n\t\"\\é"})
    json = JSON.encode!(candidate)
    bytes = byte_size(json)
    assert {:ok, _manifest} = Manifest.decode(json, max_manifest_bytes: bytes)
    assert {:ok, _manifest} = Manifest.validate(candidate, max_manifest_bytes: bytes)

    assert %{limit: :max_manifest_bytes} =
             assert_invalid(candidate, :invalid_manifest, max_manifest_bytes: bytes - 1)

    assert {:error, %Error{details: %{limit: :max_manifest_bytes}}} =
             Manifest.decode(json <> " ", max_manifest_bytes: bytes)
  end

  test "bounds nesting and node counts before decoding as well as on decoded data", %{
    fixture: data
  } do
    nested = Enum.reduce(1..80, nil, fn _, item -> [item] end)
    candidate = put_in(data, ["extensions"], %{"vendor:deep" => nested})
    assert %{limit: :max_depth} = assert_invalid(candidate)

    assert {:error, %Error{details: %{limit: :max_depth}}} =
             Manifest.decode(JSON.encode!(candidate))

    assert {:ok, _manifest} = Manifest.validate(candidate, max_depth: 100)
    assert {:ok, _manifest} = Manifest.decode(JSON.encode!(candidate), max_depth: 100)

    assert %{limit: :max_nodes} = assert_invalid(data, :invalid_manifest, max_nodes: 10)

    assert {:error, %Error{details: %{limit: :max_nodes}}} =
             Manifest.decode(JSON.encode!(data), max_nodes: 10)

    # Brackets and escaped quotes inside a JSON string are not container levels.
    text = String.duplicate("[\\\"{", 100)
    candidate = put_in(data, ["extensions"], %{"vendor:text" => text})
    assert {:ok, _manifest} = Manifest.decode(JSON.encode!(candidate), max_depth: 8)
  end

  test "bounds artifact counts, global files and bytes, and each compressed archive", %{
    fixture: data
  } do
    [artifact] = data["artifacts"]
    two = %{data | "artifacts" => [artifact, %{artifact | "id" => "second"}]}

    assert {:ok, _manifest} =
             Manifest.validate(data,
               max_artifacts: 1,
               max_files: 3,
               max_archive_bytes: 1024,
               max_unpacked_bytes: 832
             )

    assert %{limit: :max_artifacts} = assert_invalid(two, :invalid_manifest, max_artifacts: 1)
    assert %{limit: :max_files} = assert_invalid(two, :invalid_manifest, max_files: 5)

    assert %{limit: :max_unpacked_bytes} =
             assert_invalid(two, :invalid_manifest, max_unpacked_bytes: 1663)

    assert %{limit: :max_archive_bytes} =
             assert_invalid(data, :invalid_manifest, max_archive_bytes: 1023)

    assert {:ok, _manifest} =
             Manifest.validate(two, max_artifacts: 2, max_files: 6, max_unpacked_bytes: 1664)

    extreme =
      update_in(data, artifact_path() ++ ["files"], fn files ->
        Enum.map(files, &Map.put(&1, "size", 1.0e308))
      end)

    assert %{limit: :max_unpacked_bytes} = assert_invalid(extreme)
  end

  test "rejects invalid, unknown, repeated and malformed limit options", %{fixture: data} do
    for opts <- [
          nil,
          %{},
          [unknown: 1],
          [max_nodes: 0],
          [max_nodes: 1.0],
          [max_nodes: 1, max_nodes: 2],
          [{"max_nodes", 1}],
          [{:max_nodes, 1} | :improper]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} = Manifest.validate(data, opts)
      assert {:error, %Error{code: :invalid_configuration}} = Manifest.decode("{}", opts)
    end
  end

  defp artifact_path, do: ["artifacts", Access.at(0)]
  defp update_at(data, [], fun), do: fun.(data)
  defp update_at(data, path, fun), do: update_in(data, path, fun)

  defp assert_invalid(data, code \\ :invalid_manifest, opts \\ []) do
    assert {:error, %Error{code: ^code, details: details}} = Manifest.validate(data, opts)
    assert is_map(details)
    details
  end
end
