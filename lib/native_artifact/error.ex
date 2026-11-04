defmodule NativeArtifact.Error do
  @moduledoc """
  Structured failures shared by the planned native artifact lifecycle.

  `code` identifies the failure boundary; `details` contains caller-owned data
  such as a manifest field path or compatibility requirement. These errors never
  select source compilation. Callers must redact credentials before logging
  details, URLs or underlying transport errors.
  """

  @codes [
    :invalid_manifest,
    :unsupported_schema,
    :unsupported_artifact_kind,
    :unknown_target,
    :unsupported_target,
    :incompatible_artifact,
    :ambiguous_artifact,
    :artifact_not_found,
    :network_failed,
    :auth_failed,
    :tls_failed,
    :header_limit_exceeded,
    :checksum_mismatch,
    :unsafe_archive,
    :offline_cache_miss,
    :build_tool_missing,
    :load_failed,
    :invalid_configuration
  ]

  @type code ::
          :invalid_manifest
          | :unsupported_schema
          | :unsupported_artifact_kind
          | :unknown_target
          | :unsupported_target
          | :incompatible_artifact
          | :ambiguous_artifact
          | :artifact_not_found
          | :network_failed
          | :auth_failed
          | :tls_failed
          | :header_limit_exceeded
          | :checksum_mismatch
          | :unsafe_archive
          | :offline_cache_miss
          | :build_tool_missing
          | :load_failed
          | :invalid_configuration

  @enforce_keys [:code, :details]
  defstruct [:code, :details]

  @type t :: %__MODULE__{code: code(), details: map()}

  @doc "Returns the closed set of failure classifications in this contract."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc "Constructs a failure without raising, logging or selecting a recovery action."
  @spec new(code(), map()) :: t()
  def new(code, details \\ %{}) when code in @codes and is_map(details) do
    %__MODULE__{code: code, details: details}
  end
end
