defmodule NativeArtifact.ResolverTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Error, Resolver, Target}
  alias NativeArtifact.ResolutionFixture, as: Fixture

  test "selects a compatible pinned artifact using only explicit evidence" do
    expected = Fixture.artifact()

    assert {:ok, %{artifact: ^expected, rejections: []}} =
             Resolver.resolve(Fixture.manifest(), Fixture.evidence())
  end

  test "retains normalized evidence with sorted symbol lists and explicit unknown fields" do
    evidence =
      put_in(Fixture.evidence(), [:system_libraries, "libc.so.6", :symbol_versions], [
        "GLIBC_2.31",
        "GLIBC_2.28"
      ])

    evidence = put_in(evidence, [:system_libraries, "optional.so"], %{})
    evidence = Map.delete(evidence, :os_version)
    assert {:ok, resolution} = Resolver.resolve(Fixture.manifest(), evidence)
    assert resolution.evidence.os_version == nil

    assert resolution.evidence.system_libraries["libc.so.6"].symbol_versions == [
             "GLIBC_2.28",
             "GLIBC_2.31"
           ]

    assert resolution.evidence.system_libraries["optional.so"] == %{
             symbols: nil,
             symbol_versions: nil
           }

    assert resolution.evidence.target === evidence.target
    assert resolution.evidence.binding === evidence.binding
    assert {:ok, plan} = NativeArtifact.plan(Fixture.manifest(), evidence: evidence)
    assert plan.evidence === resolution.evidence
    assert {:ok, ^plan} = NativeArtifact.Plan.revalidate(plan)
  end

  test "distinguishes a platform with no candidate from an incompatible NIF" do
    {:ok, mac} = Target.new(%{"os" => "macos", "arch" => "aarch64", "libc" => "none"})

    assert {:error, %Error{code: :unsupported_target}} =
             Resolver.resolve(Fixture.manifest(), %{target: mac})

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(Fixture.manifest(), %{Fixture.evidence() | nif: {2, 16}})
  end

  test "compatible ties are ambiguous regardless of manifest order, unless selected by ID" do
    candidates = [Fixture.artifact("z"), Fixture.artifact("a")]

    assert {:error, %Error{code: :ambiguous_artifact, details: first}} =
             Resolver.resolve(Fixture.with_artifacts(candidates), Fixture.evidence())

    assert {:error, %Error{code: :ambiguous_artifact, details: ^first}} =
             Resolver.resolve(
               Fixture.with_artifacts(Enum.reverse(candidates)),
               Fixture.evidence()
             )

    assert first.candidates == ["a", "z"]

    assert {:ok, %{artifact: %{"id" => "z"}}} =
             Resolver.resolve(Fixture.with_artifacts(candidates), Fixture.evidence(),
               artifact_id: "z"
             )
  end

  test "NIF matching compares numeric minors and requires equal majors" do
    for {required, actual, compatible?} <- [
          {{2, 9}, {2, 17}, true},
          {{2, 17}, {2, 9}, false},
          {{2, 17}, {2, 17}, true},
          {{2, 17}, {3, 0}, false}
        ] do
      {major, minor} = required

      artifact =
        put_in(Fixture.artifact(), ["compatibility", "nif"], %{"major" => major, "minor" => minor})

      result =
        Resolver.resolve(Fixture.with_artifacts([artifact]), %{Fixture.evidence() | nif: actual})

      if compatible?,
        do: assert({:ok, _resolution} = result),
        else: assert({:error, %Error{code: :incompatible_artifact}} = result)
    end
  end

  test "ERTS and libc minimums compare padded numeric components" do
    for {required, actual, compatible?} <- [
          {"15.9", "15.10", true},
          {"15.10", "15.9", false},
          {"15.2.0", "15.2", true},
          {"15.2", "15.2.0.0", true},
          {"0015.0002", "15.2", true},
          {"9.9", "10.0", true}
        ] do
      for {metadata_field, evidence_field} <- [
            {"min_erts", :erts},
            {"min_libc_version", :libc_version}
          ] do
        artifact = put_in(Fixture.artifact(), ["compatibility", metadata_field], required)

        result =
          Resolver.resolve(
            Fixture.with_artifacts([artifact]),
            Map.put(Fixture.evidence(), evidence_field, actual)
          )

        if compatible?,
          do: assert({:ok, _resolution} = result),
          else: assert({:error, %Error{code: :incompatible_artifact}} = result)
      end
    end
  end

  test "Linux kernel requirements remain optional and fail closed when declared" do
    assert {:ok, _resolution} = Resolver.resolve(Fixture.manifest(), Fixture.evidence())
    artifact = put_in(Fixture.artifact(), ["compatibility", "min_os_version"], "6.1")
    manifest = Fixture.with_artifacts([artifact])

    assert {:error, %Error{code: :unknown_target, details: %{rejections: [%{reasons: reasons}]}}} =
             Resolver.resolve(manifest, Fixture.evidence())

    assert %{field: :os_version, reason: :missing_evidence} in reasons

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(manifest, %{Fixture.evidence() | os_version: "6.0.9"})

    assert {:ok, _resolution} =
             Resolver.resolve(manifest, %{Fixture.evidence() | os_version: "6.1.0"})
  end

  test "macOS requires macOS evidence and does not invent a libc requirement" do
    {:ok, target} = Target.new(%{"os" => "macos", "arch" => "aarch64", "libc" => "none"})

    artifact =
      Fixture.artifact()
      |> put_in(["target"], %{
        "os" => "macos",
        "arch" => "aarch64",
        "libc" => "none",
        "object_format" => "mach-o",
        "pointer_width" => 64,
        "endianness" => "little",
        "cpu_baseline" => "armv8-a"
      })
      |> put_in(["compatibility", "min_os_version"], "13.0")
      |> put_in(["compatibility", "min_libc_version"], nil)
      |> put_in(["compatibility", "system_libraries"], [])

    evidence = %{Fixture.evidence() | target: target, libc_version: nil, system_libraries: nil}

    assert {:error, %Error{code: :unknown_target}} =
             Resolver.resolve(Fixture.with_artifacts([artifact]), evidence)

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(Fixture.with_artifacts([artifact]), %{evidence | os_version: "12.9"})

    assert {:ok, _resolution} =
             Resolver.resolve(Fixture.with_artifacts([artifact]), %{evidence | os_version: "13.0"})
  end

  test "missing evidence differs from known incompatibility and absent libraries" do
    for field <- [:nif, :erts, :libc_version, :vm_variant, :binding, :system_libraries] do
      evidence = Map.delete(Fixture.evidence(), field)

      assert {:error, %Error{code: :unknown_target}} =
               Resolver.resolve(Fixture.manifest(), evidence)
    end

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(Fixture.manifest(), %{Fixture.evidence() | vm_variant: "other"})

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(Fixture.manifest(), %{Fixture.evidence() | system_libraries: %{}})

    evidence = %{
      Fixture.evidence()
      | system_libraries: %{"libc.so.6" => %{symbols: [], symbol_versions: nil}}
    }

    assert {:error, %Error{code: :unknown_target}} =
             Resolver.resolve(Fixture.manifest(), evidence)

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(
               Fixture.manifest(),
               put_in(evidence, [:system_libraries, "libc.so.6", :symbol_versions], [])
             )
  end

  test "required symbols and symbol versions need exact inventory evidence" do
    artifact =
      put_in(
        Fixture.artifact(),
        ["compatibility", "system_libraries", Access.at(0), "required_symbols"],
        ["malloc"]
      )

    manifest = Fixture.with_artifacts([artifact])
    assert {:ok, _resolution} = Resolver.resolve(manifest, Fixture.evidence())

    for {field, value, code} <- [
          {:symbols, [], :incompatible_artifact},
          {:symbols, nil, :unknown_target},
          {:symbol_versions, ["GLIBC_2.99"], :incompatible_artifact}
        ] do
      evidence = put_in(Fixture.evidence(), [:system_libraries, "libc.so.6", field], value)
      assert {:error, %Error{code: ^code}} = Resolver.resolve(manifest, evidence)
    end
  end

  test "binding identity must match the pinned wrapper exactly without interning names" do
    for {field, value} <- [
          {"module", "Elixir.Other.Native"},
          {"interface_version", "2"},
          {"fingerprint", String.duplicate("f", 64)}
        ] do
      evidence = put_in(Fixture.evidence(), [:binding, field], value)

      assert {:error, %Error{code: :incompatible_artifact}} =
               Resolver.resolve(Fixture.manifest(), evidence)
    end

    name = "Elixir.UninternedResolver#{System.unique_integer([:positive])}.Native"
    artifact = put_in(Fixture.artifact(), ["binding", "module"], name)
    evidence = put_in(Fixture.evidence(), [:binding, "module"], name)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert {:ok, _resolution} = Resolver.resolve(Fixture.with_artifacts([artifact]), evidence)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "selecting an ID never falls back to a different compatible artifact" do
    wrong = put_in(Fixture.artifact("too-new"), ["compatibility", "nif", "minor"], 99)
    manifest = Fixture.with_artifacts([wrong, Fixture.artifact("working")])

    assert {:ok, %{artifact: %{"id" => "working"}}} =
             Resolver.resolve(manifest, Fixture.evidence())

    assert {:error, %Error{code: :incompatible_artifact}} =
             Resolver.resolve(manifest, Fixture.evidence(), artifact_id: "too-new")

    assert {:error, %Error{code: :artifact_not_found}} =
             Resolver.resolve(manifest, Fixture.evidence(), artifact_id: "absent")
  end

  test "candidate order and version labels do not create implicit preferences" do
    wrong_nif = put_in(Fixture.artifact("a"), ["compatibility", "nif", "minor"], 99)
    wrong_binding = put_in(Fixture.artifact("z"), ["binding", "module"], "Elixir.Other.Native")
    working = Fixture.artifact("middle")
    candidates = [wrong_binding, working, wrong_nif]
    assert {:ok, first} = Resolver.resolve(Fixture.with_artifacts(candidates), Fixture.evidence())

    assert {:ok, second} =
             Resolver.resolve(
               Fixture.with_artifacts(Enum.reverse(candidates)),
               Fixture.evidence()
             )

    assert first.artifact == second.artifact
    assert first.rejections == second.rejections
    assert Enum.map(first.rejections, & &1.artifact_id) == ["a", "z"]

    newer = %{
      working
      | "id" => "newer",
        "native_version" => "not-semver",
        "build_revision" => 100
    }

    assert {:error, %Error{code: :ambiguous_artifact}} =
             Resolver.resolve(Fixture.with_artifacts([working, newer]), Fixture.evidence())
  end

  test "integer-valued schema numbers match canonical runtime numbers" do
    artifact =
      Fixture.artifact()
      |> put_in(["target", "pointer_width"], 64.0)
      |> put_in(["compatibility", "nif"], %{"major" => 2.0, "minor" => 17.0})
      |> put_in(["archive", "size"], 1024.0)

    evidence = %{Fixture.evidence() | nif: {2.0, 17.0}}

    assert {:ok, %{artifact: ^artifact}} =
             Resolver.resolve(Fixture.with_artifacts([artifact]), evidence)
  end

  test "revalidates Manifest structs, preserves limits, and treats strings only as JSON" do
    assert {:ok, manifest} = NativeArtifact.Manifest.validate(Fixture.manifest())

    assert {:ok, resolution} =
             Resolver.resolve(manifest, Fixture.evidence(),
               manifest_limits: [max_archive_bytes: 2048]
             )

    assert resolution.manifest_limits == [max_archive_bytes: 2048]

    assert {:ok, _resolution} =
             Resolver.resolve(JSON.encode!(Fixture.manifest()), Fixture.evidence())

    assert {:error, %Error{code: :invalid_manifest}} =
             Resolver.resolve(%{manifest | data: %{}}, Fixture.evidence())

    assert {:error, %Error{code: :invalid_manifest}} =
             Resolver.resolve(%{__struct__: NativeArtifact.Manifest}, Fixture.evidence())

    path = Path.expand("../fixtures/manifest-v1.json", __DIR__)
    assert {:error, %Error{code: :invalid_manifest}} = Resolver.resolve(path, Fixture.evidence())

    assert {:error, %Error{code: :invalid_manifest}} =
             Resolver.resolve(Fixture.manifest(), Fixture.evidence(),
               manifest_limits: [max_archive_bytes: 100]
             )
  end

  test "rejects malformed evidence, forged targets and malformed options without raising" do
    for evidence <- [
          [],
          %URI{},
          %{Fixture.evidence() | nif: "2.17"},
          %{Fixture.evidence() | erts: "16.2\n"},
          %{Fixture.evidence() | vm_variant: :beam},
          %{Fixture.evidence() | binding: %{}},
          %{Fixture.evidence() | system_libraries: %{"libc.so.6" => %URI{}}},
          %{Fixture.evidence() | system_libraries: %{:atom_name => %{}}},
          put_in(Fixture.evidence(), [:system_libraries, "libc.so.6", :symbols], ["malloc" | :bad])
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Resolver.resolve(Fixture.manifest(), evidence)
    end

    for {field, value} <- [
          pointer_width: 32,
          endianness: :big,
          cpu_baseline: :native,
          source: :inferred
        ] do
      evidence = put_in(Fixture.evidence(), [:target, Access.key(field)], value)

      assert {:error, %Error{code: :unsupported_target}} =
               Resolver.resolve(Fixture.manifest(), evidence)
    end

    assert {:error, %Error{code: :unknown_target}} =
             Resolver.resolve(Fixture.manifest(), %{__struct__: Target} |> then(&%{target: &1}))

    assert {:error, %Error{code: :unknown_target}} = Resolver.resolve(Fixture.manifest(), nil)

    for opts <- [
          nil,
          %{},
          [unknown: true],
          [artifact_id: "a", artifact_id: "b"],
          [{:artifact_id, "a"} | :bad],
          [artifact_id: "https://secret@example.invalid"]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Resolver.resolve(Fixture.manifest(), Fixture.evidence(), opts)
    end
  end

  test "diagnostics do not echo library names or invalid evidence containing secrets" do
    artifact =
      put_in(
        Fixture.artifact(),
        ["compatibility", "system_libraries", Access.at(0), "name"],
        "https://secret@example.invalid"
      )

    assert {:error, %Error{details: details}} =
             Resolver.resolve(Fixture.with_artifacts([artifact]), Fixture.evidence())

    refute inspect(details) =~ "secret"

    assert {:error, %Error{details: details}} =
             Resolver.resolve(Fixture.manifest(), Map.put(Fixture.evidence(), :unknown, "secret"))

    refute inspect(details) =~ "secret"
  end

  test "public evidence limits reject oversized inventories and values" do
    oversized =
      put_in(
        Fixture.evidence(),
        [:binding, "interface_version"],
        String.duplicate("a", 4 * 1024 * 1024)
      )

    libraries = Map.new(1..257, &{"library#{&1}", %{symbols: [], symbol_versions: []}})
    symbols = Enum.map(1..4097, &"symbol#{&1}")

    too_many_symbols =
      put_in(Fixture.evidence(), [:system_libraries, "libc.so.6", :symbols], symbols)

    for evidence <- [
          oversized,
          %{Fixture.evidence() | system_libraries: libraries},
          too_many_symbols,
          %{Fixture.evidence() | erts: "1." <> String.duplicate("0", 127)},
          %{Fixture.evidence() | erts: <<255>>}
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Resolver.resolve(Fixture.manifest(), evidence)
    end
  end
end
