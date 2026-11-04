defmodule NativeArtifact do
  @moduledoc """
  Contracts for managing precompiled NIF bundles.

  This initial P0 implementation defines explicit target descriptions and
  structured errors. Manifest v1 is specified in `native/artifacts.schema.json`.
  Resolution, downloading, installation, build adapters and Mix integration are
  not implemented yet. No platform has completed runtime certification.
  """
end
