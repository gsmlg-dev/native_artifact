defmodule NativeArtifact.PlanTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Error, Plan, Target}
  alias NativeArtifact.ResolutionFixture, as: Fixture

  test "the public facade defaults to an inspectable precompiled plan" do
    assert {:ok, %{__struct__: Plan, mode: :precompiled, artifact: artifact, execution: :pending}} =
             NativeArtifact.plan(Fixture.manifest(), evidence: Fixture.evidence())

    assert artifact === Fixture.artifact()
  end

  test "source plans require explicit mode and keep source output identity pending" do
    {:ok, target} = Target.new(%{"os" => "macos", "arch" => "aarch64", "libc" => "none"})
    evidence = %{target: target, binding: Fixture.artifact()["binding"]}
    recipe = {NativeArtifact.Build.Make, [path: "c_src"]}

    assert {:ok,
            %{
              mode: :source,
              artifact: nil,
              archive: nil,
              sources: [],
              build: ^recipe,
              source_identity: identity
            }} =
             NativeArtifact.plan(Fixture.manifest(),
               mode: :source,
               evidence: evidence,
               artifact_id: Fixture.artifact()["id"],
               build: recipe
             )

    assert identity.origin == :local_build
    assert identity.output_sha256 == nil
  end

  test "auto and unknown modes are rejected without executing a build" do
    for mode <- [:auto, :other, "source"] do
      assert {:error, %Error{code: :invalid_configuration}} =
               NativeArtifact.plan(Fixture.manifest(), mode: mode, evidence: Fixture.evidence())
    end
  end

  test "precompiled plans expose pinned identity, diagnostics and ordered future actions" do
    bad = put_in(Fixture.artifact("rejected"), ["compatibility", "nif", "minor"], 99)
    manifest = Fixture.with_artifacts([bad, Fixture.artifact()])
    limits = [max_archive_bytes: 2048]
    assert {:ok, plan} = Plan.new(manifest, evidence: Fixture.evidence(), manifest_limits: limits)
    assert plan.manifest.data === manifest
    assert plan.manifest_limits === limits
    assert plan.evidence === Fixture.evidence()
    assert plan.selector == nil
    assert plan.archive === Fixture.artifact()["archive"]
    assert plan.sources === Fixture.artifact()["sources"]
    assert plan.binding === Fixture.artifact()["binding"]
    assert [%{artifact_id: "rejected"}] = plan.rejections

    assert plan.actions == [
             :obtain_archive,
             :verify_archive,
             :inspect_archive,
             :install_transactionally,
             :write_receipt
           ]

    assert plan.build == nil
    assert plan.source_identity == nil
  end

  test "explicit source recipes remain declarative for each approved adapter" do
    for build <- [
          {NativeArtifact.Build.Make, [path: "c_src"]},
          {NativeArtifact.Build.Cargo, [path: "native/codec", locked: true]},
          {NativeArtifact.Build.Zig, [path: "native/codec"]}
        ] do
      assert {:ok, plan} = Plan.new(Fixture.manifest(), source_opts(build))
      assert plan.build === build
      assert plan.execution == :pending
      assert plan.artifact == nil
      assert plan.archive == nil
      assert plan.sources == []
      assert plan.source_identity.provenance === Fixture.artifact()["provenance"]
      assert plan.source_identity.output_sha256 == nil
      assert plan.source_identity.receipt == :pending
      refute Map.has_key?(plan.source_identity, :archive_sha256)

      assert plan.actions == [
               :build_source,
               :verify_local_output,
               :install_transactionally,
               :write_source_receipt
             ]
    end
  end

  test "source requires explicit target, bundle identity, pinned binding and recipe" do
    opts = source_opts({NativeArtifact.Build.Make, [path: "c_src"]})

    for field <- [:artifact_id, :build] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Plan.new(Fixture.manifest(), Keyword.delete(opts, field))
    end

    for evidence <- [
          %{Fixture.evidence() | binding: nil},
          Map.delete(Fixture.evidence(), :target)
        ] do
      assert {:error, %Error{code: :unknown_target}} =
               Plan.new(Fixture.manifest(), Keyword.put(opts, :evidence, evidence))
    end

    evidence = put_in(Fixture.evidence(), [:binding, "interface_version"], "wrong")

    assert {:error, %Error{code: :incompatible_artifact}} =
             Plan.new(Fixture.manifest(), Keyword.put(opts, :evidence, evidence))
  end

  test "source ignores precompiled NIF, libc and system-library requirements" do
    target = Fixture.evidence().target
    evidence = %{target: target, binding: Fixture.artifact()["binding"]}

    opts =
      Keyword.put(source_opts({NativeArtifact.Build.Make, [path: "c_src"]}), :evidence, evidence)

    assert {:ok, %{mode: :source}} = Plan.new(Fixture.manifest(), opts)

    assert {:error, %Error{code: :unknown_target}} =
             Plan.new(Fixture.manifest(), evidence: evidence)
  end

  test "source rejects unsafe recipes and never invokes caller code" do
    for path <- [
          nil,
          "/tmp/source",
          "../source",
          "C:source",
          "a\\b",
          "a//b",
          "a/",
          "a/./b",
          "a\nb",
          String.duplicate("a", 4097)
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Plan.new(
                 Fixture.manifest(),
                 source_opts({NativeArtifact.Build.Make, [path: path]})
               )
    end

    callback = fn -> send(self(), :build_was_called) end

    for recipe <- [
          callback,
          {NativeArtifact.Build.Make, [path: "c_src", command: callback]},
          {NativeArtifact.Build.Cargo, [path: "native", locked: false]},
          {NativeArtifact.Build.Make, [path: "native", locked: true]},
          {String, [path: "native"]}
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Plan.new(Fixture.manifest(), source_opts(recipe))
    end

    refute_received :build_was_called
  end

  test "precompiled failures never return source plans or execute a supplied recipe" do
    evidence = %{Fixture.evidence() | nif: {2, 0}}

    assert {:error, %Error{code: :incompatible_artifact}} =
             Plan.new(Fixture.manifest(), evidence: evidence)

    assert {:error, %Error{code: :invalid_configuration}} =
             Plan.new(Fixture.manifest(),
               evidence: evidence,
               build: {NativeArtifact.Build.Make, [path: "c_src"]}
             )
  end

  test "the facade rejects malformed options and revalidates supplied Manifest structs" do
    for opts <- [
          nil,
          %{},
          [extra: true],
          [mode: :source, mode: :source],
          [{:mode, :source} | :bad]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               NativeArtifact.plan(Fixture.manifest(), opts)
    end

    assert {:ok, manifest} = NativeArtifact.Manifest.validate(Fixture.manifest())
    assert {:ok, _plan} = NativeArtifact.plan(manifest, evidence: Fixture.evidence())

    assert {:error, %Error{code: :invalid_manifest}} =
             NativeArtifact.plan(%{manifest | data: %{}}, evidence: Fixture.evidence())
  end

  defp source_opts(build) do
    [
      mode: :source,
      evidence: Fixture.evidence(),
      artifact_id: Fixture.artifact()["id"],
      build: build
    ]
  end
end
