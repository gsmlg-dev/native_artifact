defmodule NativeArtifact.InstallTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.Error
  alias NativeArtifact.ResolutionFixture, as: ResolutionFixture
  alias NativeArtifact.Test.LocalArchiveFixture, as: ArchiveFixture
  alias NativeArtifact.Test.LocalInstallationFixture, as: InstallationFixture

  setup do
    root = ArchiveFixture.temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    context = InstallationFixture.create(root)

    assert {:ok, plan} =
             NativeArtifact.plan(context.manifest, evidence: ResolutionFixture.evidence())

    Map.merge(context, %{root: root, plan: plan})
  end

  test "installs a freshly validated precompiled plan through the local public facade", context do
    assert {:ok, result} =
             NativeArtifact.install(context.plan,
               archive_path: context.archive_path,
               priv_dir: context.priv
             )

    assert result.directory == context.final
    assert result.receipt["mode"] == "precompiled"
    assert File.read!(result.entrypoint) == "opaque NIF bytes"
    refute result.reused?

    File.rm!(context.archive_path)
    assert {:ok, reused} = install(context.plan, context)
    assert reused.reused?
    assert reused.directory == result.directory
  end

  test "rejects corrupt local archive bytes without promoting an installation", context do
    File.write!(context.archive_path, "corrupt archive")
    assert {:error, %Error{}} = install(context.plan, context)
    refute File.exists?(context.final)
  end

  test "recreates default selection without losing rejected-candidate diagnostics", context do
    rejected =
      context.artifact
      |> Map.put("id", "rejected")
      |> put_in(["compatibility", "nif", "minor"], 99)

    manifest = Map.put(context.manifest, "artifacts", [rejected, context.artifact])
    assert {:ok, plan} = NativeArtifact.plan(manifest, evidence: ResolutionFixture.evidence())
    assert plan.selector == nil
    assert [%{artifact_id: "rejected"}] = plan.rejections
    assert {:ok, _result} = install(plan, context)
  end

  test "recreates an explicit selection among otherwise compatible ties", context do
    other = Map.put(context.artifact, "id", "other")
    manifest = Map.put(context.manifest, "artifacts", [other, context.artifact])

    assert {:ok, plan} =
             NativeArtifact.plan(manifest,
               evidence: ResolutionFixture.evidence(),
               artifact_id: context.artifact_id
             )

    assert plan.selector == context.artifact_id
    assert {:ok, _result} = install(plan, context)
  end

  test "rejects inconsistent duplicated plan data before filesystem work", context do
    for {field, value} <- [
          mode: :auto,
          artifact: Map.put(context.plan.artifact, "build_revision", 99),
          artifact_id: "other",
          selector: "missing",
          archive: Map.put(context.plan.archive, "sha256", String.duplicate("0", 64)),
          sources: [],
          actions: [],
          target: %{context.plan.target | arch: :aarch64},
          binding: Map.put(context.plan.binding, "interface_version", "changed"),
          rejections: [%{artifact_id: "invented", reasons: []}],
          execution: :complete,
          build: {NativeArtifact.Build.Make, [path: "c_src"]},
          source_identity: %{origin: :local_build}
        ] do
      assert {:error, %Error{}} = install(Map.put(context.plan, field, value), context),
             "accepted inconsistent #{field}"

      assert File.ls!(context.priv) == []
    end
  end

  test "revalidates retained evidence, manifest and manifest limits before writes", context do
    for evidence <- [
          %{context.plan.evidence | nif: {2, 0}},
          %{context.plan.evidence | binding: nil},
          %{context.plan.evidence | system_libraries: %{}},
          %{context.plan.evidence | target: nil},
          Map.put(context.plan.evidence, :unknown, true),
          "not evidence"
        ] do
      assert {:error, %Error{}} = install(%{context.plan | evidence: evidence}, context)
      assert File.ls!(context.priv) == []
    end

    for manifest <- [
          nil,
          %{},
          %{context.plan.manifest | data: %{}},
          Map.delete(context.plan.manifest, :data)
        ] do
      assert {:error, %Error{}} = install(%{context.plan | manifest: manifest}, context)
      assert File.ls!(context.priv) == []
    end

    for limits <- [
          [max_archive_bytes: 1],
          [max_files: 0],
          [unknown: 1],
          [max_files: 10, max_files: 11],
          %{}
        ] do
      assert {:error, %Error{}} = install(%{context.plan | manifest_limits: limits}, context)
      assert File.ls!(context.priv) == []
    end
  end

  test "rejects non-plan, extra-field and partial struct shapes safely", context do
    for plan <- [
          nil,
          %{},
          Map.from_struct(context.plan),
          Map.put(context.plan, :extra, true),
          Map.delete(context.plan, :evidence),
          %{__struct__: NativeArtifact.Plan}
        ] do
      assert {:error, %Error{code: :invalid_configuration}} = install(plan, context)
      assert File.ls!(context.priv) == []
    end
  end

  test "validates the narrow execution option set before writes", context do
    valid = [archive_path: context.archive_path, priv_dir: context.priv]

    for opts <- [
          nil,
          %{},
          [:bad],
          [{:timeout, 1} | :bad],
          valid ++ [timeout: 1, timeout: 2],
          valid ++ [archive_path: context.archive_path],
          valid ++ [mode: :source],
          valid ++ [artifact_id: context.artifact_id],
          valid ++ [manifest_limits: []],
          valid ++ [evidence: context.plan.evidence],
          valid ++ [build: {NativeArtifact.Build.Make, [path: "c_src"]}],
          valid ++ [timeout: 0],
          valid ++ [timeout: -1],
          valid ++ [timeout: 1.0],
          valid ++ [timeout: :infinity],
          valid ++ [archive_limits: nil],
          valid ++ [archive_limits: [unknown: 1]],
          valid ++ [archive_limits: [max_files: 0]],
          valid ++ [archive_limits: [max_files: 1.0]],
          valid ++ [archive_limits: [max_files: 10, max_files: 11]],
          [],
          [archive_path: context.archive_path],
          [priv_dir: context.priv]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               NativeArtifact.install(context.plan, opts)

      assert File.ls!(context.priv) == []
    end

    for key <- [:archive_path, :priv_dir],
        path <- [
          nil,
          "",
          "relative",
          "/a/../b",
          "/a/./b",
          "/a//b",
          "/a/",
          "/a\nb",
          <<255>>,
          String.duplicate("a", 4097)
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               NativeArtifact.install(context.plan, Keyword.put(valid, key, path))

      assert File.ls!(context.priv) == []
    end
  end

  test "forwards supported finite archive limits to local installation", context do
    assert {:error, %Error{}} =
             NativeArtifact.install(context.plan,
               archive_path: context.archive_path,
               priv_dir: context.priv,
               archive_limits: [max_archive_bytes: 1]
             )

    refute File.exists?(context.final)
  end

  test "source execution remains explicitly pending without filesystem work", context do
    opts = [
      mode: :source,
      evidence: ResolutionFixture.evidence(),
      artifact_id: context.artifact_id,
      build: {NativeArtifact.Build.Make, [path: "c_src"]}
    ]

    assert {:ok, plan} = NativeArtifact.plan(context.manifest, opts)

    assert {:error,
            %Error{code: :invalid_configuration, details: %{reason: :source_execution_pending}}} =
             NativeArtifact.install(plan, [])

    assert File.ls!(context.priv) == []

    for changed <- [
          %{plan | build: nil},
          %{plan | source_identity: %{origin: :official}},
          %{plan | actions: []}
        ] do
      assert {:error, %Error{code: :invalid_configuration}} = install(changed, context)
      assert File.ls!(context.priv) == []
    end
  end

  defp install(plan, context),
    do: NativeArtifact.install(plan, archive_path: context.archive_path, priv_dir: context.priv)
end
