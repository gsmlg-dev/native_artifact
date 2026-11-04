defmodule NativeArtifact.TargetTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.{Error, Target}

  test "all six proposed targets normalize explicit BEAM platform data" do
    for arch <- ["x86_64", "aarch64"], libc <- ["glibc", "musl"] do
      assert {:ok,
              %Target{
                os: :linux,
                libc: normalized_libc,
                object_format: :elf,
                pointer_width: 64,
                endianness: :little,
                source: :explicit
              }} = Target.new(%{"os" => "linux", "arch" => arch, "libc" => libc})

      assert normalized_libc in [:glibc, :musl]
    end

    for arch <- ["x86_64", "aarch64"] do
      assert {:ok, %Target{os: :macos, libc: :none, object_format: :mach_o}} =
               Target.new(%{"os" => "macos", "arch" => arch, "libc" => "none"})
    end
  end

  test "explicit x86_64 macOS target is not replaced with the physical host architecture" do
    assert {:ok, %Target{arch: :x86_64, cpu_baseline: :x86_64}} =
             Target.new(%{"os" => "macos", "arch" => "x86_64", "libc" => "none"})

    assert {:ok, %Target{arch: :aarch64, cpu_baseline: :armv8_a}} =
             Target.new(%{"os" => "macos", "arch" => "aarch64", "libc" => "none"})
  end

  test "missing, unknown and non-map targets fail without assuming GNU" do
    assert {:error, %Error{code: :unknown_target, details: %{field: "libc"}}} =
             Target.new(%{"os" => "linux", "arch" => "x86_64"})

    for libc <- [nil, "unknown", "gnu", :glibc] do
      assert {:error, %Error{code: :unknown_target, details: %{field: "libc"}}} =
               Target.new(%{"os" => "linux", "arch" => "x86_64", "libc" => libc})
    end

    assert {:error, %Error{code: :unknown_target}} = Target.new(nil)
    assert {:error, %Error{code: :unknown_target}} = Target.new(%{})
  end

  test "unsupported libc combinations and platform invariants are rejected" do
    assert {:error, %Error{code: :unsupported_target}} =
             Target.new(%{"os" => "macos", "arch" => "aarch64", "libc" => "glibc"})

    base = %{"os" => "linux", "arch" => "x86_64", "libc" => "musl"}

    for {field, value} <- [
          {"pointer_width", 32},
          {"endianness", "big"},
          {"object_format", "mach-o"},
          {"cpu_baseline", "native"}
        ] do
      assert {:error, %Error{code: :unsupported_target, details: %{field: ^field}}} =
               Target.new(Map.put(base, field, value))
    end

    assert {:ok, %Target{libc: :musl}} =
             Target.new(Map.merge(base, %{"pointer_width" => 64, "cpu_baseline" => "x86-64"}))
  end

  test "unrecognized input keys and architecture strings are rejected as data" do
    assert {:error, %Error{code: :unknown_target, details: %{reason: :unknown_fields}}} =
             Target.new(%{os: "linux", arch: "x86_64", libc: "glibc"})

    untrusted = "native_artifact_untrusted_arch_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(untrusted) end

    assert {:error, %Error{code: :unknown_target, details: %{field: "arch"}}} =
             Target.new(%{"os" => "linux", "arch" => untrusted, "libc" => "glibc"})

    assert_raise ArgumentError, fn -> String.to_existing_atom(untrusted) end
  end

  test "NIF versions compare numeric minor values and conservatively require equal majors" do
    assert {:ok, {2, 17}} = Target.parse_nif_version("2.17")
    assert {:ok, {2, 9}} = Target.parse_nif_version("2.9")
    assert Target.nif_compatible?({2, 9}, {2, 17})
    assert Target.nif_compatible?({2, 17}, {2, 17})
    refute Target.nif_compatible?({2, 17}, {2, 9})
    refute Target.nif_compatible?({2, 17}, {3, 0})
    refute Target.nif_compatible?({3, 0}, {2, 17})
    refute Target.nif_compatible?({2, -1}, {2, 17})
    refute Target.nif_compatible?("2.17", "2.18")
  end

  test "malformed NIF versions return structured errors" do
    for version <- ["2", "2.17.0", "2.17\n", "0.1", "-2.17", "2.-1", "2.x", nil, 2.17] do
      assert {:error, %Error{code: :invalid_configuration, details: %{field: :nif_version}}} =
               Target.parse_nif_version(version)
    end
  end
end
