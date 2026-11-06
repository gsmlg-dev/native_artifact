defmodule NativeArtifact.InstallerTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Error, Installer, Manifest}
  alias NativeArtifact.Test.LocalArchiveFixture, as: ArchiveFixture
  alias NativeArtifact.Test.LocalInstallationFixture, as: Fixture

  setup do
    root = ArchiveFixture.temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    Map.put(Fixture.create(root), :root, root)
  end

  test "installs complete local bytes and a separate portable receipt", context do
    assert {:ok, result} = install(context)
    assert result.directory == context.final
    assert result.payload_directory == Path.join(context.final, "payload")
    assert result.entrypoint == Path.join(context.final, "payload/lib/codec.so")
    assert result.reused? == false
    assert result.receipt["mode"] == "precompiled"
    assert result.receipt["receipt_version"] == 1
    assert result.receipt["package"] == "example_codec"
    assert result.receipt["artifact"]["entrypoint"] == "payload/lib/codec.so"
    assert File.read!(result.entrypoint) == "opaque NIF bytes"

    assert File.read!(Path.join(result.payload_directory, "receipt.json")) ==
             "payload-owned metadata"

    stored = context.final |> Path.join("receipt.json") |> File.read!() |> JSON.decode!()
    assert stored == result.receipt
    refute String.contains?(JSON.encode!(stored), context.root)
    assert Enum.sort(File.ls!(context.final)) == ["payload", "receipt.json"]
    assert Bitwise.band(File.stat!(context.final).mode, 0o7777) == 0o755
  end

  test "reuses only verified installed bytes even when the original archive is gone", context do
    assert {:ok, first} = install(context)
    File.rm!(context.archive_path)
    assert {:ok, reused} = install(context)
    assert reused.reused?
    assert reused.receipt == first.receipt
    assert File.read!(reused.entrypoint) == "opaque NIF bytes"
  end

  test "invalid manifest and archive identities leave no final installation", context do
    malformed =
      put_in(context.manifest, ["artifacts", Access.at(0), "archive", "sha256"], "invalid")

    assert {:error, %Error{code: :invalid_manifest}} =
             Installer.install(malformed, context.artifact_id, context.archive_path,
               priv_dir: context.priv
             )

    refute File.exists?(Path.join(context.priv, "native"))
    File.write!(context.archive_path, "wrong bytes")
    assert {:error, %Error{code: :checksum_mismatch}} = install(context)
    refute File.exists?(context.final)
  end

  test "accepts revalidated Manifest structs and whole-valued JSON numbers", context do
    data =
      context.manifest
      |> update_in(["artifacts", Access.at(0), "archive", "size"], &(&1 * 1.0))
      |> update_in(["artifacts", Access.at(0), "files", Access.at(0), "size"], &(&1 * 1.0))
      |> put_in(["artifacts", Access.at(0), "build_revision"], 1.0)

    assert {:ok, manifest} = Manifest.validate(data)

    assert {:ok, first} =
             Installer.install(manifest, context.artifact_id, context.archive_path,
               priv_dir: context.priv
             )

    assert first.receipt["artifact"]["build_revision"] === 1
    assert {:ok, reused} = install(context)
    assert reused.reused?
    forged = %Manifest{data: Map.put(data, "schema_version", 2)}

    assert {:error, %Error{code: :unsupported_schema}} =
             Installer.install(forged, context.artifact_id, context.archive_path,
               priv_dir: context.priv
             )
  end

  test "two package versions may reuse a native digest without mutating old receipts", context do
    assert {:ok, first} = install(context)
    first_receipt = File.read!(Path.join(first.directory, "receipt.json"))
    newer = Map.put(context.manifest, "package_version", "0.2.0")

    assert {:ok, second} =
             Installer.install(newer, context.artifact_id, context.archive_path,
               priv_dir: context.priv
             )

    refute second.reused?
    refute first.directory == second.directory
    assert Path.basename(first.directory) == Path.basename(second.directory)
    assert first.receipt["package_version"] == "0.1.0"
    assert second.receipt["package_version"] == "0.2.0"
    assert File.read!(Path.join(first.directory, "receipt.json")) == first_receipt
    assert File.read!(second.entrypoint) == File.read!(first.entrypoint)
  end

  test "rejects changed receipt identity while preserving the valid installation", context do
    assert {:ok, first} = install(context)

    changed =
      put_in(context.manifest, ["artifacts", Access.at(0), "binding", "interface_version"], "2")

    before = File.read!(Path.join(first.directory, "receipt.json"))

    assert {:error, %Error{code: :checksum_mismatch}} =
             Installer.install(changed, context.artifact_id, context.archive_path,
               priv_dir: context.priv
             )

    assert File.read!(Path.join(first.directory, "receipt.json")) == before
    assert File.read!(first.entrypoint) == "opaque NIF bytes"
  end

  test "rejects corrupted installed content without replacing it", context do
    assert {:ok, first} = install(context)
    File.write!(first.entrypoint, "changed NIF byte")
    assert {:error, %Error{code: :checksum_mismatch}} = install(context)
    assert File.read!(first.entrypoint) == "changed NIF byte"
  end

  test "rejects missing and extra installed files or directories", context do
    assert {:ok, first} = install(context)
    File.rm!(Path.join(first.payload_directory, "LICENSE"))
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    refute File.exists?(Path.join(first.payload_directory, "LICENSE"))
    File.write!(Path.join(first.payload_directory, "LICENSE"), "MIT")
    File.write!(Path.join(first.payload_directory, "extra"), "unowned")
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.read!(Path.join(first.payload_directory, "extra")) == "unowned"
    File.rm!(Path.join(first.payload_directory, "extra"))
    File.mkdir!(Path.join(first.directory, "extra-dir"))
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.dir?(Path.join(first.directory, "extra-dir"))
  end

  test "rejects file and directory mode changes", context do
    assert {:ok, first} = install(context)
    File.chmod!(first.entrypoint, 0o755)
    assert {:error, %Error{code: :checksum_mismatch}} = install(context)
    assert Bitwise.band(File.stat!(first.entrypoint).mode, 0o7777) == 0o755
    File.chmod!(first.entrypoint, 0o644)
    File.chmod!(first.payload_directory, 0o700)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert Bitwise.band(File.stat!(first.payload_directory).mode, 0o7777) == 0o700
  end

  test "rejects symlink and hardlink installed files without following or deleting targets",
       context do
    assert {:ok, first} = install(context)
    outside = Path.join(context.root, "outside")
    File.write!(outside, "opaque NIF bytes")
    File.rm!(first.entrypoint)
    File.ln_s!(outside, first.entrypoint)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.lstat!(first.entrypoint).type == :symlink
    assert File.read!(outside) == "opaque NIF bytes"
    File.rm!(first.entrypoint)
    File.ln!(outside, first.entrypoint)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.stat!(outside).links == 2
  end

  test "rejects malformed, duplicate-key, oversized and missing receipts", context do
    assert {:ok, first} = install(context)
    path = Path.join(first.directory, "receipt.json")
    valid = File.read!(path)

    for bytes <- [
          "{broken",
          "{\"receipt_version\":1," <> binary_part(valid, 1, byte_size(valid) - 1),
          :binary.copy("x", byte_size(valid) + 2048)
        ] do
      File.write!(path, bytes)
      assert {:error, %Error{code: :checksum_mismatch}} = install(context)
      assert File.read!(path) == bytes
    end

    File.rm!(path)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    refute File.exists?(path)
  end

  test "rejects symlink installation roots and unsafe namespace parents", context do
    parent = Path.dirname(context.final)
    File.mkdir_p!(parent)
    outside = Path.join(context.root, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "preserved"), "owned")
    File.ln_s!(outside, context.final)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.lstat!(context.final).type == :symlink
    File.rm!(context.final)
    File.rmdir!(parent)
    File.ln_s!(outside, parent)
    assert {:error, %Error{code: :invalid_configuration}} = install(context)
    assert File.read!(Path.join(outside, "preserved")) == "owned"
    assert File.ls!(outside) == ["preserved"]
  end

  test "an existing incomplete digest directory is preserved and rejected", context do
    File.mkdir_p!(context.final)
    assert {:error, %Error{code: :unsafe_archive}} = install(context)
    assert File.ls!(context.final) == []
  end

  test "archive failure cleans only this attempt's staging and preserves unrelated stages",
       context do
    parent = Path.dirname(context.final)
    File.mkdir_p!(parent)
    unrelated = Path.join(parent, ".install-unrelated")
    File.mkdir!(unrelated)
    File.write!(Path.join(unrelated, "owned"), "preserved")
    File.write!(context.archive_path, "wrong")
    assert {:error, %Error{code: :checksum_mismatch}} = install(context)
    assert File.ls!(parent) == [".install-unrelated"]
    assert File.read!(Path.join(unrelated, "owned")) == "preserved"
    refute File.exists?(context.final)
  end

  test "limits apply to existing installation reuse too", context do
    assert {:ok, first} = install(context)

    assert {:error, %Error{code: :invalid_manifest}} =
             install(context, archive_limits: [max_files: 1])

    assert {:error, %Error{code: :invalid_configuration}} =
             install(context, archive_limits: [unknown: 1])

    assert File.read!(first.entrypoint) == "opaque NIF bytes"
  end

  test "unknown selections and malformed arguments are structured without writes", context do
    for manifest <- [nil, [], %URI{}, %Manifest{data: %{}}, [%{} | :improper]] do
      assert {:error, %Error{}} =
               Installer.install(manifest, context.artifact_id, context.archive_path,
                 priv_dir: context.priv
               )
    end

    for opts <- [
          nil,
          %{},
          [{:priv_dir, context.priv} | :improper],
          [priv_dir: context.priv, unknown: 1],
          [priv_dir: context.priv, priv_dir: context.priv],
          [priv_dir: context.priv, timeout: :infinity],
          [priv_dir: context.priv, manifest_limits: %{}],
          [priv_dir: context.priv, archive_limits: [{:max_files, 1} | :improper]]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Installer.install(
                 context.manifest,
                 context.artifact_id,
                 context.archive_path,
                 opts
               )
    end

    assert {:error, %Error{code: :artifact_not_found}} =
             Installer.install(context.manifest, "missing", context.archive_path,
               priv_dir: context.priv
             )

    assert {:error, %Error{code: :invalid_configuration}} =
             Installer.install(context.manifest, :invalid, context.archive_path,
               priv_dir: context.priv
             )

    assert {:error, %Error{code: :invalid_configuration}} =
             Installer.install(context.manifest, context.artifact_id, "relative.tar.gz",
               priv_dir: context.priv
             )

    refute File.exists?(Path.join(context.priv, "native"))
  end

  test "a symlink priv root is rejected without writing through it", context do
    link = Path.join(context.root, "priv-link")
    File.ln_s!(context.priv, link)
    assert {:error, %Error{code: :invalid_configuration}} = install(context, priv_dir: link)
    assert File.ls!(context.priv) == []
  end

  test "independent BEAM processes converge on one fully verified installation", context do
    child_root = Path.join(context.root, "concurrent")
    File.mkdir!(child_root)
    child = Fixture.create(child_root, body: :binary.copy("x", 1_000_000))
    first = child(child, child_root, "install")
    second = child(child, child_root, "install")
    ready(first)
    ready(second)
    Port.command(first, "GO\n")
    Port.command(second, "GO\n")
    {first_code, first_output} = finished(first)
    {second_code, second_output} = finished(second)
    assert first_code == 0, first_output
    assert second_code == 0, second_output
    results = [result_json(first_output), result_json(second_output)]
    assert Enum.sort(Enum.map(results, & &1["reused"])) == [false, true]
    assert {:ok, verified} = install(child)
    assert verified.reused?
    assert File.ls!(Path.dirname(child.final)) == [Path.basename(child.final)]
  end

  test "interruption before promotion leaves no consumable partial and a new attempt recovers",
       context do
    child_root = Path.join(context.root, "interrupted")
    File.mkdir!(child_root)
    child = Fixture.create(child_root, body: :binary.copy("x", 40_000_000))
    process = child(child, child_root, "interrupt")
    ready(process)
    Port.command(process, "GO\n")

    stage =
      wait_for_stage(Path.dirname(child.final), System.monotonic_time(:millisecond) + 10_000)

    refute File.exists?(child.final)
    Port.command(process, "HALT\n")
    {code, output} = finished(process)
    assert code == 137, output
    refute File.exists?(child.final)
    assert File.dir?(stage)
    assert {:ok, recovered} = install(child)
    refute recovered.reused?
    assert File.dir?(stage)
    assert File.stat!(recovered.entrypoint).size == 40_000_000
  end

  defp install(context, opts \\ []) do
    Installer.install(
      context.manifest,
      context.artifact_id,
      context.archive_path,
      Keyword.merge([priv_dir: context.priv], opts)
    )
  end

  defp child(context, root, mode) do
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, JSON.encode!(context.manifest))

    modules = ~w(
      lib/native_artifact/error.ex
      lib/native_artifact/manifest/json.ex
      lib/native_artifact/manifest.ex
      lib/native_artifact/archive/support.ex
      lib/native_artifact/archive/gzip.ex
      lib/native_artifact/archive/ustar.ex
      lib/native_artifact/archive.ex
      lib/native_artifact/installer/support.ex
      lib/native_artifact/installer/receipt.ex
      lib/native_artifact/installer/verifier.ex
      lib/native_artifact/installer.ex
    )

    code = ~S"""
    [manifest_path, artifact_id, archive_path, priv, mode] = System.argv()
    manifest = manifest_path |> File.read!() |> JSON.decode!()
    IO.puts("READY")
    if IO.gets("") != "GO\n", do: :erlang.halt(137)
    run = fn ->
      case NativeArtifact.Installer.install(manifest, artifact_id, archive_path, priv_dir: priv) do
        {:ok, result} -> IO.puts(JSON.encode!(%{status: "ok", reused: result.reused?})); :erlang.halt(0)
        {:error, error} -> IO.puts(JSON.encode!(%{status: "error", code: Atom.to_string(error.code)})); :erlang.halt(1)
      end
    end
    if mode == "interrupt" do
      Task.start(run)
      IO.gets("")
      :erlang.halt(137)
    else
      run.()
    end
    """

    args =
      Enum.flat_map(modules, &["-r", Path.expand(&1)]) ++
        [
          "-e",
          code,
          "--",
          manifest_path,
          context.artifact_id,
          context.archive_path,
          context.priv,
          mode
        ]

    process =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :use_stdio,
        :stderr_to_stdout,
        :exit_status,
        {:args, args},
        {:env, [{~c"ERL_FLAGS", ~c"+S 2:2 +A 1"}]}
      ])

    on_exit(fn ->
      if Port.info(process) do
        Port.command(process, "HALT\n")
        Port.close(process)
      end
    end)

    process
  end

  defp ready(process, output \\ "") do
    receive do
      {^process, {:data, bytes}} ->
        output = output <> bytes
        if String.contains?(output, "READY\n"), do: :ok, else: ready(process, output)

      {^process, {:exit_status, code}} ->
        flunk("child exited before READY (#{code}): #{output}")
    after
      15_000 -> flunk("child did not become READY: #{output}")
    end
  end

  defp finished(process, output \\ "") do
    receive do
      {^process, {:data, bytes}} -> finished(process, output <> bytes)
      {^process, {:exit_status, code}} -> {code, output}
    after
      20_000 -> flunk("child did not stop: #{output}")
    end
  end

  defp result_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, "{"))
    |> JSON.decode!()
  end

  defp wait_for_stage(parent, deadline) do
    names =
      case File.ls(parent) do
        {:ok, names} -> names
        {:error, :enoent} -> []
      end

    case Enum.find(names, &String.starts_with?(&1, ".install-")) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("no staging directory appeared")

        Process.sleep(5)
        wait_for_stage(parent, deadline)

      name ->
        Path.join(parent, name)
    end
  end
end
