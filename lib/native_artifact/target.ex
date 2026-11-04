defmodule NativeArtifact.Target do
  @moduledoc """
  Explicit platform descriptions for the six proposed v0.1 targets.

  `new/1` accepts string-keyed data, never host information or a language-specific
  triple. It performs no OS probing, process execution, network requests or atom
  creation. An explicit target describes the intended BEAM, which can differ from
  the physical machine (for example, an x86_64 BEAM under Rosetta).

  These are candidate platform contracts, not a list of certified platforms.
  Minimum OS/libc/ERTS versions and system-library requirements live in the
  manifest's compatibility record and require later resolver/runtime checks.
  """

  alias NativeArtifact.Error

  @keys ~w(os arch libc object_format pointer_width endianness cpu_baseline)
  @os_values %{"linux" => :linux, "macos" => :macos}
  @arch_values %{"x86_64" => :x86_64, "aarch64" => :aarch64}
  @libc_values %{"glibc" => :glibc, "musl" => :musl, "none" => :none}

  @enforce_keys [:os, :arch, :libc, :object_format, :cpu_baseline]
  defstruct [
    :os,
    :arch,
    :libc,
    :object_format,
    :cpu_baseline,
    pointer_width: 64,
    endianness: :little,
    source: :explicit
  ]

  @type t :: %__MODULE__{
          os: :linux | :macos,
          arch: :x86_64 | :aarch64,
          libc: :glibc | :musl | :none,
          object_format: :elf | :mach_o,
          pointer_width: 64,
          endianness: :little,
          cpu_baseline: :x86_64 | :armv8_a,
          source: :explicit
        }
  @type nif_version :: {pos_integer(), non_neg_integer()}

  @doc """
  Validates an explicit target, deriving only fixed platform invariants.

  `os`, `arch` and `libc` are required; unknown libc is never treated as GNU.
  Optional invariant fields must match the selected platform exactly.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         {:ok, os} <- enum(attrs, "os", @os_values),
         {:ok, arch} <- enum(attrs, "arch", @arch_values),
         {:ok, libc} <- enum(attrs, "libc", @libc_values),
         :ok <- validate_libc(os, libc),
         target = target(os, arch, libc),
         :ok <- validate_invariants(attrs, target) do
      {:ok, target}
    end
  end

  def new(_attrs), do: failure(:unknown_target, %{reason: :expected_map})

  @doc "Parses an NIF API version without interpreting it as a decimal number."
  @spec parse_nif_version(term()) :: {:ok, nif_version()} | {:error, Error.t()}
  def parse_nif_version(version) when is_binary(version) and byte_size(version) <= 32 do
    case Regex.run(~r/\A([1-9][0-9]*)\.([0-9]+)\z/, version, capture: :all_but_first) do
      [major, minor] -> {:ok, {String.to_integer(major), String.to_integer(minor)}}
      nil -> failure(:invalid_configuration, %{field: :nif_version, reason: :invalid_version})
    end
  end

  def parse_nif_version(_version) do
    failure(:invalid_configuration, %{field: :nif_version, reason: :invalid_version})
  end

  @doc """
  Tests only the conservative NIF API requirement: same major, required minor
  no newer than runtime minor. It does not prove overall artifact compatibility.
  """
  @spec nif_compatible?(term(), term()) :: boolean()
  def nif_compatible?({major, required_minor}, {major, runtime_minor})
      when is_integer(major) and major > 0 and is_integer(required_minor) and
             required_minor >= 0 and is_integer(runtime_minor) and runtime_minor >= 0,
      do: required_minor <= runtime_minor

  def nif_compatible?(_required, _runtime), do: false

  defp validate_keys(attrs) do
    case Map.keys(attrs) -- @keys do
      [] -> :ok
      keys -> failure(:unknown_target, %{reason: :unknown_fields, fields: keys})
    end
  end

  defp enum(attrs, field, values) do
    case Map.fetch(attrs, field) do
      :error -> failure(:unknown_target, %{field: field, reason: :missing_field})
      {:ok, nil} -> failure(:unknown_target, %{field: field, reason: :unknown_value})
      {:ok, value} -> lookup_value(field, value, values)
    end
  end

  defp lookup_value(field, value, values) do
    case Map.fetch(values, value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> failure(:unknown_target, %{field: field, reason: :unknown_value})
    end
  end

  defp validate_libc(:linux, libc) when libc in [:glibc, :musl], do: :ok
  defp validate_libc(:macos, :none), do: :ok

  defp validate_libc(os, libc) do
    failure(:unsupported_target, %{os: os, libc: libc, reason: :unsupported_libc_combination})
  end

  defp target(os, arch, libc) do
    %__MODULE__{
      os: os,
      arch: arch,
      libc: libc,
      object_format: if(os == :linux, do: :elf, else: :mach_o),
      cpu_baseline: if(arch == :x86_64, do: :x86_64, else: :armv8_a)
    }
  end

  defp validate_invariants(attrs, target) do
    expected = %{
      "object_format" => if(target.object_format == :elf, do: "elf", else: "mach-o"),
      "pointer_width" => target.pointer_width,
      "endianness" => "little",
      "cpu_baseline" => if(target.cpu_baseline == :x86_64, do: "x86-64", else: "armv8-a")
    }

    Enum.reduce_while(expected, :ok, fn {field, value}, :ok ->
      case Map.fetch(attrs, field) do
        :error ->
          {:cont, :ok}

        {:ok, ^value} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt,
           failure(:unsupported_target, %{
             field: field,
             expected: value,
             reason: :unsupported_invariant
           })}
      end
    end)
  end

  defp failure(code, details), do: {:error, Error.new(code, details)}
end
