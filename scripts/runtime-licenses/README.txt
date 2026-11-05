Redistribution notices for the bundled GigaFlow runtime

CPython and its embedded dependencies:
  PythonBuildStandalone/ contains the unmodified licenses shipped in
  python-build-standalone 3.11.18, release 20261026, aarch64-apple-darwin.
  SOURCE.json identifies the upstream archive and its SHA256.
  Upstream build sources and dependency download recipes:
  https://github.com/astral-sh/python-build-standalone/tree/20261026
  https://github.com/python/cpython/tree/v3.11.18

GigaAM model:
  GigaAM-MIT.txt is the upstream GigaAM MIT license.
  https://github.com/salute-developers/GigaAM/blob/main/LICENSE
  Model source and card:
  https://huggingface.co/aystream/GigaAM-v3-e2e-rnnt-mlx/tree/decfca492069ea30fb5ead79c4516d50c16d93ea

Installed Python packages:
  Their original *.dist-info/METADATA, license files and package notices are
  retained in Runtime/python/lib/python3.11/site-packages. Runtime/package
  versions are listed in runtime-manifest.json. The GigaFlow source repository
  also contains THIRDPARTY.md and the exact requirements.lock.txt.

These notices describe external components; they do not assign a license to
GigaFlow's own source code. Some Python build notices cover optional components
of the upstream distribution, whether or not those modules are used by GigaFlow.
