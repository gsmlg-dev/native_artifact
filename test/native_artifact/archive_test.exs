defmodule NativeArtifact.ArchiveTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Archive, Error}
  alias NativeArtifact.Test.LocalArchiveFixture, as: Fixture

  setup do
    root = Fixture.temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, staging: Path.join(root, "staging")}
  end

  test "verifies and extracts exact regular files with normalized modes", context do
    files = [
      Fixture.file("lib/codec.so", "opaque NIF bytes", role: "nif"),
      Fixture.file("data/tool", "opaque executable bytes", mode: "0755")
    ]

    tar =
      Fixture.tar([
        Fixture.entry("lib/", "", type: "5", mode: 0o755),
        Fixture.entry("lib/codec.so", "opaque NIF bytes"),
        Fixture.entry("data/tool", "opaque executable bytes", mode: 0o755)
      ])

    {path, artifact} = Fixture.write(context.root, files, tar)
    assert {:ok, result} = Archive.extract(path, artifact, context.staging)
    assert result.directory == context.staging
    assert result.files == ["data/tool", "lib/codec.so"]
    assert result.entrypoint == "lib/codec.so"
    assert result.archive_sha256 == artifact["archive"]["sha256"]
    assert File.read!(Path.join(context.staging, "lib/codec.so")) == "opaque NIF bytes"
    assert Bitwise.band(File.stat!(Path.join(context.staging, "data/tool")).mode, 0o7777) == 0o755
    assert Enum.sort(File.ls!(context.staging)) == ["data", "lib"]
  end

  test "a wrong compressed identity leaves no staging or unrelated damage", context do
    files = [Fixture.file("codec.so", "bytes", role: "nif")]

    {path, artifact} =
      Fixture.write(context.root, files, Fixture.tar([Fixture.entry("codec.so", "bytes")]))

    File.write!(Path.join(context.root, "unrelated"), "preserved")
    artifact = put_in(artifact, ["archive", "sha256"], String.duplicate("0", 64))

    assert {:error, %Error{code: :checksum_mismatch}} =
             Archive.extract(path, artifact, context.staging)

    refute File.exists?(context.staging)
    assert File.read!(Path.join(context.root, "unrelated")) == "preserved"
  end

  test "does not overwrite an existing staging directory", context do
    files = [Fixture.file("codec.so", "bytes", role: "nif")]

    {path, artifact} =
      Fixture.write(context.root, files, Fixture.tar([Fixture.entry("codec.so", "bytes")]))

    File.mkdir!(context.staging)
    File.write!(Path.join(context.staging, "owned"), "preserved")

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract(path, artifact, context.staging)

    assert File.read!(Path.join(context.staging, "owned")) == "preserved"
  end

  test "accepts a USTAR prefix and zero-sized regular files", context do
    files = [Fixture.file("nested/codec.so", "", role: "nif")]
    tar = Fixture.tar([Fixture.entry("codec.so", "", prefix: "nested")])
    {path, artifact} = Fixture.write(context.root, files, tar)
    assert {:ok, _result} = Archive.extract(path, artifact, context.staging)
    assert File.read!(Path.join(context.staging, "nested/codec.so")) == ""
  end

  test "accepts whole-valued JSON number sizes without changing caller metadata", context do
    {path, artifact} = sample(context)

    artifact =
      artifact
      |> update_in(["archive", "size"], &(&1 * 1.0))
      |> update_in(["files", Access.at(0), "size"], &(&1 * 1.0))

    assert {:ok, _result} = Archive.extract(path, artifact, context.staging)
    assert is_float(artifact["archive"]["size"])
    assert is_float(hd(artifact["files"])["size"])
    assert File.read!(Path.join(context.staging, "codec.so")) == "bytes"
  end

  test "rejects fractional, huge and negative JSON sizes structurally", context do
    {path, artifact} = sample(context)

    for row <- [
          put_in(artifact, ["archive", "size"], 92.5),
          put_in(artifact, ["archive", "size"], 1.0e308),
          put_in(artifact, ["files", Access.at(0), "size"], 5.5),
          put_in(artifact, ["files", Access.at(0), "size"], -1.0),
          put_in(artifact, ["files", Access.at(0), "size"], 1.0e308)
        ] do
      assert {:error, %Error{code: :invalid_manifest}} =
               Archive.extract(path, row, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "accepts aligned zero record padding after the mandatory end markers", context do
    tar = Fixture.tar([Fixture.entry("codec.so", "bytes")], :binary.copy(<<0>>, 5120))
    {path, artifact} = Fixture.write(context.root, files(), tar)
    assert {:ok, _result} = Archive.extract(path, artifact, context.staging)
  end

  test "rejects actual compressed lengths shorter and longer than the pinned size", context do
    {path, artifact} = sample(context)

    for difference <- [-1, 1] do
      changed = update_in(artifact, ["archive", "size"], &(&1 + difference))

      assert {:error, %Error{code: :checksum_mismatch, details: %{field: :size}}} =
               Archive.extract(path, changed, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects a per-file digest mismatch after a valid compressed identity", context do
    {path, artifact} = sample(context)
    changed = put_in(artifact, ["files", Access.at(0), "sha256"], String.duplicate("0", 64))

    assert {:error, %Error{code: :checksum_mismatch, details: %{stage: :file}}} =
             Archive.extract(path, changed, context.staging)

    refute File.exists?(context.staging)
  end

  test "rejects file size and mode mismatches", context do
    for entries <- [
          [Fixture.entry("codec.so", "wrong-size")],
          [Fixture.entry("codec.so", "bytes", mode: 0o755)]
        ] do
      {path, artifact} = Fixture.write(context.root, files(), Fixture.tar(entries))

      assert {:error, %Error{code: :unsafe_archive}} =
               Archive.extract(path, artifact, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects truncated gzip and corrupted CRC with recomputed compressed identities",
       context do
    gzip = :zlib.gzip(Fixture.tar([Fixture.entry("codec.so", "bytes")]))
    crc_offset = byte_size(gzip) - 8
    <<crc_byte>> = binary_part(gzip, crc_offset, 1)
    bad_crc = Fixture.replace(gzip, crc_offset, 1, <<Bitwise.bxor(crc_byte, 1)>>)

    for bytes <- [binary_part(gzip, 0, byte_size(gzip) - 1), bad_crc] do
      {path, artifact} = Fixture.write(context.root, files(), "", gzip: bytes)

      assert {:error, %Error{code: :unsafe_archive, details: %{stage: :gzip}}} =
               Archive.extract(path, artifact, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects trailing gzip bytes and additional gzip members", context do
    gzip = :zlib.gzip(Fixture.tar([Fixture.entry("codec.so", "bytes")]))

    for suffix <- [<<0>>, "ignored junk", :zlib.gzip("another member")] do
      {path, artifact} = Fixture.write(context.root, files(), "", gzip: gzip <> suffix)

      assert {:error, %Error{code: :unsafe_archive, details: %{reason: :trailing_gzip_data}}} =
               Archive.extract(path, artifact, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects a bad tar header checksum", context do
    tar = Fixture.tar([Fixture.entry("codec.so", "bytes")]) |> Fixture.replace(0, 1, "x")
    assert_rejected_tar(context, tar, :tar_checksum)
  end

  test "rejects base-256 and malformed numeric fields", context do
    header = Fixture.header(Fixture.entry("codec.so", "bytes"))

    for value <- [<<128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5>>, "00000000009\0"] do
      header = header |> Fixture.replace(124, 12, value) |> checksum()
      tar = header <> "bytes" <> :binary.copy(<<0>>, 507 + 1024)
      assert_rejected_tar(context, tar, :invalid_numeric_field)
    end
  end

  test "rejects hidden bytes after NUL terminators and extra USTAR metadata", context do
    base = Fixture.header(Fixture.entry("codec.so", "bytes"))

    for header <- [
          Fixture.replace(base, 9, 1, "x"),
          Fixture.replace(base, 500, 1, "x"),
          Fixture.replace(base, 329, 8, "0000001\0"),
          Fixture.replace(base, 157, 1, "x")
        ] do
      tar = checksum(header) <> "bytes" <> :binary.copy(<<0>>, 507 + 1024)
      assert_rejected_tar(context, tar)
    end
  end

  test "rejects unsafe entry paths even when the archive digest matches", context do
    for name <- [
          "../escape",
          "/absolute",
          "./codec.so",
          "a//b",
          "a/../b",
          "C:/drive",
          "a\\b",
          "a\nb",
          <<255>>
        ] do
      tar = Fixture.tar([Fixture.entry(name, "bytes")])
      assert_rejected_tar(context, tar, :unsafe_path)
    end
  end

  test "rejects link, device, sparse and extension header types", context do
    for type <- ["1", "2", "3", "4", "6", "7", "x", "g", "L", "K", "S", "z"] do
      tar = Fixture.tar([Fixture.entry("codec.so", "bytes", type: type)])
      assert_rejected_tar(context, tar, :unsupported_tar_type)
    end
  end

  test "rejects non-USTAR encodings", context do
    tar = Fixture.tar([Fixture.entry("codec.so", "bytes", magic: "ustar ")])
    assert_rejected_tar(context, tar, :unsupported_tar_format)
  end

  test "rejects unlisted, missing and duplicate files", context do
    for {entries, reason} <- [
          {[Fixture.entry("other.so", "bytes")], :unlisted_file},
          {[], :missing_files},
          {[Fixture.entry("codec.so", "bytes"), Fixture.entry("codec.so", "bytes")],
           :duplicate_path}
        ] do
      assert_rejected_tar(context, Fixture.tar(entries), reason)
    end
  end

  test "rejects unnecessary, duplicate, payload-bearing and unsafe-mode directories", context do
    nested_files = [Fixture.file("lib/codec.so", "bytes", role: "nif")]

    for entries <- [
          [
            Fixture.entry("other/", "", type: "5", mode: 0o755),
            Fixture.entry("lib/codec.so", "bytes")
          ],
          [
            Fixture.entry("lib/", "", type: "5", mode: 0o755),
            Fixture.entry("lib/", "", type: "5", mode: 0o755)
          ],
          [Fixture.entry("lib/", "x", type: "5", mode: 0o755)],
          [Fixture.entry("lib/", "", type: "5", mode: 0o777)]
        ] do
      {path, artifact} = Fixture.write(context.root, nested_files, Fixture.tar(entries))

      assert {:error, %Error{code: :unsafe_archive}} =
               Archive.extract(path, artifact, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects nonzero file padding and malformed tar end markers", context do
    base = Fixture.tar([Fixture.entry("codec.so", "bytes")])
    nonzero_padding = Fixture.replace(base, 517, 1, "x")
    assert_rejected_tar(context, nonzero_padding, :nonzero_file_padding)

    for tail <- [
          :binary.copy(<<0>>, 512),
          :binary.copy(<<0>>, 512) <> :binary.copy("x", 512),
          :binary.copy(<<0>>, 1024) <> <<0>>,
          :binary.copy(<<0>>, 1024) <> :binary.copy("x", 512)
        ] do
      assert_rejected_tar(context, Fixture.tar([Fixture.entry("codec.so", "bytes")], tail))
    end
  end

  test "rejects compressed, payload, file and implicit-directory metadata limits", context do
    {path, artifact} = sample(context)

    for opts <- [[max_archive_bytes: 1], [max_unpacked_bytes: 1]] do
      assert {:error, %Error{code: :invalid_manifest}} =
               Archive.extract(path, artifact, context.staging, opts)

      refute File.exists?(context.staging)
    end

    many_files = files() ++ [Fixture.file("data", "")]

    {path, artifact} =
      Fixture.write(context.root, many_files, Fixture.tar([Fixture.entry("codec.so", "bytes")]))

    assert {:error, %Error{code: :invalid_manifest}} =
             Archive.extract(path, artifact, context.staging, max_files: 1)

    nested = [Fixture.file("one/two/codec.so", "bytes", role: "nif")]

    {path, artifact} =
      Fixture.write(
        context.root,
        nested,
        Fixture.tar([Fixture.entry("one/two/codec.so", "bytes")])
      )

    assert {:error, %Error{code: :invalid_manifest}} =
             Archive.extract(path, artifact, context.staging, max_directories: 1)

    refute File.exists?(context.staging)
  end

  test "bounds inflated tar bytes and headers before extraction", context do
    {path, artifact} = sample(context)

    assert {:error, %Error{code: :unsafe_archive, details: %{reason: :inflated_size_limit}}} =
             Archive.extract(path, artifact, context.staging, max_tar_overhead_bytes: 1024)

    refute File.exists?(context.staging)
    nested = [Fixture.file("lib/codec.so", "bytes", role: "nif")]

    tar =
      Fixture.tar([
        Fixture.entry("lib/", "", type: "5", mode: 0o755),
        Fixture.entry("lib/codec.so", "bytes")
      ])

    {path, artifact} = Fixture.write(context.root, nested, tar)

    assert {:error, %Error{code: :unsafe_archive, details: %{reason: :header_count_limit}}} =
             Archive.extract(path, artifact, context.staging, max_headers: 1)

    refute File.exists?(context.staging)
  end

  test "a small compressed expansion cannot bypass the raw tar budget", context do
    tar = :binary.copy(<<0>>, 2_000_000)
    {path, artifact} = Fixture.write(context.root, files(), tar)
    assert artifact["archive"]["size"] < 4096

    assert {:error, %Error{code: :unsafe_archive, details: %{reason: :inflated_size_limit}}} =
             Archive.extract(path, artifact, context.staging, max_tar_overhead_bytes: 4096)

    refute File.exists?(context.staging)
  end

  test "a finite work deadline stops processing and cleans staging", context do
    body = :binary.copy("x", 10_000_000)
    large_files = [Fixture.file("codec.so", body, role: "nif")]

    {path, artifact} =
      Fixture.write(context.root, large_files, Fixture.tar([Fixture.entry("codec.so", body)]))

    assert {:error, %Error{code: :unsafe_archive, details: %{reason: :deadline_exceeded}}} =
             Archive.extract(path, artifact, context.staging, timeout: 1)

    refute File.exists?(context.staging)
  end

  test "rejects symlink source and staging boundaries without touching their targets", context do
    {path, artifact} = sample(context)
    link = Path.join(context.root, "source-link")
    File.ln_s!(path, link)

    assert {:error, %Error{code: :unsafe_archive}} =
             Archive.extract(link, artifact, context.staging)

    refute File.exists?(context.staging)
    outside = Path.join(context.root, "outside")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "owned"), "preserved")
    File.ln_s!(outside, context.staging)

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract(path, artifact, context.staging)

    assert File.lstat!(context.staging).type == :symlink
    assert File.read!(Path.join(outside, "owned")) == "preserved"
    File.rm!(context.staging)
    parent_link = Path.join(context.root, "parent-link")
    File.ln_s!(outside, parent_link)

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract(path, artifact, Path.join(parent_link, "staging"))

    refute File.exists?(Path.join(outside, "staging"))
  end

  test "a missing archive is structured and leaves no staging", context do
    {_path, artifact} = sample(context)

    assert {:error, %Error{code: :artifact_not_found}} =
             Archive.extract(Path.join(context.root, "missing.tar.gz"), artifact, context.staging)

    refute File.exists?(context.staging)
  end

  test "rejects malformed operational metadata without exceptions or writes", context do
    {path, artifact} = sample(context)
    error = %Error{code: :invalid_manifest, details: %{}}

    for row <- [
          nil,
          [],
          error,
          %{},
          %URI{},
          put_in(artifact, ["archive"], error),
          put_in(artifact, ["archive"], %URI{}),
          put_in(artifact, ["files"], [error]),
          put_in(artifact, ["files"], [%URI{}]),
          put_in(artifact, ["files"], [hd(files()) | :improper]),
          put_in(artifact, ["files", Access.at(0), "path"], "../escape"),
          put_in(artifact, ["files", Access.at(0), "mode"], "04755"),
          put_in(artifact, ["files", Access.at(0), "size"], -1),
          put_in(artifact, ["entrypoint"], "different.so")
        ] do
      assert {:error, %Error{code: :invalid_manifest}} =
               Archive.extract(path, row, context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects duplicate and file-directory-conflicting metadata paths", context do
    {path, artifact} = sample(context)

    for rows <- [files() ++ files(), files() ++ [Fixture.file("codec.so/child", "")]] do
      assert {:error, %Error{code: :invalid_manifest}} =
               Archive.extract(path, Map.put(artifact, "files", rows), context.staging)

      refute File.exists?(context.staging)
    end
  end

  test "rejects invalid limits and nonabsolute paths without exceptions", context do
    {path, artifact} = sample(context)

    for opts <- [
          nil,
          %{},
          :invalid,
          [{:timeout, 1} | :improper],
          [unknown: 1],
          [max_files: 0],
          [max_files: -1],
          [timeout: :infinity],
          [max_files: 1, max_files: 2]
        ] do
      assert {:error, %Error{code: :invalid_configuration}} =
               Archive.extract(path, artifact, context.staging, opts)

      refute File.exists?(context.staging)
    end

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract("relative.tar.gz", artifact, context.staging)

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract(path, artifact, "relative-staging")

    assert {:error, %Error{code: :invalid_configuration}} =
             Archive.extract(path, artifact, Path.join(context.root, "missing-parent/staging"))
  end

  defp files, do: [Fixture.file("codec.so", "bytes", role: "nif")]

  defp sample(context) do
    Fixture.write(context.root, files(), Fixture.tar([Fixture.entry("codec.so", "bytes")]))
  end

  defp assert_rejected_tar(context, tar, reason \\ nil) do
    {path, artifact} = Fixture.write(context.root, files(), tar)

    assert {:error, %Error{code: :unsafe_archive, details: details}} =
             Archive.extract(path, artifact, context.staging)

    if reason, do: assert(details.reason == reason)
    refute File.exists?(context.staging)
  end

  defp checksum(header) do
    header = Fixture.replace(header, 148, 8, :binary.copy(" ", 8))
    sum = header |> :binary.bin_to_list() |> Enum.sum()
    value = (sum |> Integer.to_string(8) |> String.pad_leading(6, "0")) <> <<0, 32>>
    Fixture.replace(header, 148, 8, value)
  end
end
