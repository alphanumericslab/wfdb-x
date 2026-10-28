# Releasing WFDB-x on PyPI

The Python implementation of WFDB-x is published on PyPI as
[`wfdb-x`](https://pypi.org/project/wfdb-x/) (imported as `wfdbx`). This
page is the complete procedure for a release: the accounts and API tokens
required, the version number, the tests, building, a trial release on
TestPyPI, the release on PyPI, and what to do when something goes wrong.

The distributions are built from the `python/` directory of the
repository. They contain the `wfdbx` package, its sample record
(`src/wfdbx/sample_data`) and its example notebooks
(`src/wfdbx/examples`). The source distribution also contains the unit
tests; those that need the repository's test records are skipped when the
records are not there.

## Before the first release: accounts and API tokens

PyPI and TestPyPI are separate services, with separate accounts and
tokens.

1. **Create the accounts.** Register on
   [pypi.org](https://pypi.org/account/register/) and on
   [test.pypi.org](https://test.pypi.org/account/register/), verify the
   e-mail address on each, and turn on two-factor authentication (both
   services require it to upload).
2. **Create an API token on each service.** Uploads use API tokens, not the
   account password. On each site: *Account settings* → *API tokens* → *Add
   API token*.
   * For the very first upload of a project, the token must have the scope
     *Entire account*, because the project does not exist yet.
   * After the first upload, replace it with a token whose scope is the
     project `wfdb-x` only, and delete the account-wide token. A
     project-scoped token cannot affect the account's other projects if it
     leaks.
   * A token is shown only once. It starts with `pypi-`. Store it in a
     password manager.
3. **Give the tokens to twine.** Either write them in `~/.pypirc`, readable
   only by its owner (`chmod 600 ~/.pypirc`):

   ```ini
   [distutils]
   index-servers =
       pypi
       testpypi

   [pypi]
   username = __token__
   password = pypi-...the PyPI token...

   [testpypi]
   repository = https://test.pypi.org/legacy/
   username = __token__
   password = pypi-...the TestPyPI token...
   ```

   or pass them in the environment for one command only (the user name is
   always the literal `__token__`):

   ```sh
   TWINE_USERNAME=__token__ TWINE_PASSWORD=pypi-... twine upload dist/*
   ```

   Never commit a token to the repository. If one is exposed, delete it on
   the site at once and create a new one.
4. **Install the tools** (optionally in a virtual environment):

   ```sh
   python3 -m pip install --upgrade build twine
   ```

## 1. Choose the version number

WFDB-x follows [semantic versioning](https://semver.org), with one version
number shared by the seven implementations (see *Versions* in the project
README). It is independent of the version of the WFDB Software Package that
WFDB-x implements.

* `X.Y.Z+1` (patch): bug fixes and documentation only;
* `X.Y+1.0` (minor): new features, compatible with earlier versions;
* `X+1.0.0` (major): changes that can break existing code or scripts.

A version number can be used **only once** on PyPI (and on TestPyPI): a
file cannot be replaced, even after it is deleted. Pre-releases (PEP 440:
`1.1.0rc1`, `1.1.0b1`, `1.1.0.dev1`) are not installed by
`pip install wfdb-x` unless asked for (`pip install --pre wfdb-x`), which
makes them suitable for trial releases on PyPI itself.

The version is set in every language at once, so that they stay equal:

| Language | File |
|---|---|
| Python | `python/src/wfdbx/__init__.py` (`__version__`; the package reads it from there) |
| C++ | `cpp/CMakeLists.txt` (`project(wfdbx VERSION ...)`) |
| Rust | `rust/Cargo.toml`, `benchmarks/rust/Cargo.toml` |
| Julia | `julia/Project.toml` |
| R | `r/DESCRIPTION`, and `--version` in `r/R/cli.R` |
| Kotlin | `kotlin/build.gradle.kts`, `--version` in `kotlin/src/jvmMain/kotlin/wfdbx/cli/Main.kt`, and the coordinates in `README.md`, `kotlin/README.md` and `kotlin/DEVELOPING.md` |
| MATLAB/Octave | `matlab/+wfdbx/Contents.m`, and `--version` in `matlab/+wfdbx/+internal/cli_main.m` |

and in the sentence "the current version is ..." of the project README and
the example output of `--version` in `julia/README.md`. `grep -rn
--exclude-dir=.git --exclude-dir=third_party -F "<old version>" .` finds any
place left over (matches in `docs/BENCHMARKS.md` and in PhysioNet URLs such
as `mitdb/1.0.0` are expected). `wfdbx --version` prints `WFDB-x <version>`.

## 2. Sync the public repository first

The README of the package is its page on PyPI, and it shows the overview
figure from the public repository
(`https://raw.githubusercontent.com/alphanumericslab/wfdb-x/main/docs/overview.png`)
and links to its documents. Merge the release into `main` and update the
public repository **before** uploading, so that the figure and the links
work on the PyPI page from the start.

## 3. Test

From the repository root, in a fresh virtual environment:

```sh
python3 -m venv /tmp/wfdbx-release && . /tmp/wfdbx-release/bin/activate
pip install -e "./python[test,examples]"
pytest python/tests                         # unit tests, notebooks included
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl python -j4
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl python -j4 --legacy
```

All must pass (the two conformance suites compare every tool with the
original C programs: see [conformance.md](conformance.md)).

Quote package names with extras (`"wfdb-x[examples]"`): in zsh, the
default shell of macOS, unquoted square brackets are a pattern, and the
command fails (for example with `zsh: no matches found` or `unknown file
attribute`).

## 4. Build and check the distributions

```sh
cd python
rm -rf dist build src/*.egg-info
python3 -m build                # dist/wfdb_x-<version>.tar.gz and dist/wfdb_x-<version>-py3-none-any.whl
twine check dist/*              # the metadata, and the README as PyPI will render it
```

Check that the file names carry the new version, and look inside the wheel
(`unzip -l dist/*.whl`): the package, `sample_data/` and `examples/` must
be there.

## 5. Trial release on TestPyPI

TestPyPI is a separate copy of PyPI for trying out releases; what is
uploaded there does not reach PyPI's users.

```sh
twine upload --repository testpypi dist/*
```

Then look at the page `https://test.pypi.org/project/wfdb-x/<version>/`
(the README, the figure, the links), and install the package in a new
environment. The package must come from TestPyPI and from nowhere else:
when two indexes are given (`--index-url` and `--extra-index-url`), pip
treats them as equal and may take the same version from either. So install
the dependencies from PyPI first, then the package alone from TestPyPI,
with `--no-deps`:

```sh
python3 -m venv /tmp/wfdbx-testpypi && . /tmp/wfdbx-testpypi/bin/activate
pip install "numpy>=1.17" matplotlib jupyter    # the dependencies (and the examples' extras), from PyPI
pip install --no-deps --index-url https://test.pypi.org/simple/ "wfdb-x==<version>"
pip show wfdb-x                 # Version: <version>
wfdbx --version                 # WFDB-x <version>
WFDBX_INPUT_DIR=$(python3 -c "import wfdbx; print(wfdbx.sample_data_dir())") \
    wfdbx rdsamp -r 100s -t 2   # a tool, on the sample record
python3 -c "import wfdbx; wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir()); print(wfdbx.read_record('100s').signals.shape)"
wfdbx --examples ex && ls ex    # the example notebooks
```

(The dependencies are those of `python/pyproject.toml`: `dependencies`, and
the `examples` extra.) Remember that the version just uploaded to TestPyPI
cannot be uploaded there again: to try again after a fix, use the next
version, or a pre-release number such as `1.1.0rc2`.

## 6. Release on PyPI

```sh
twine upload dist/*
```

Check `https://pypi.org/project/wfdb-x/`, and install it in a new
environment (`pip install --upgrade wfdb-x`, then `wfdbx --version`).

Then tag the release in git and push the tag:

```sh
git tag v<version>
git push origin v<version>
```

and, optionally, create a GitHub release from the tag with a summary of
the changes.

## If something goes wrong

| Problem | Cause and remedy |
|---|---|
| `400 File already exists` | That version was uploaded before (perhaps deleted since). Versions cannot be reused: set the next version, rebuild, upload. |
| `403 Invalid or non-existent authentication information` | Wrong token, or a TestPyPI token used on PyPI (or the reverse). The user name must be `__token__`, the password the whole token, `pypi-` included. |
| `403 The user ... isn't allowed to upload to project` | The token is scoped to another project, or (first upload) not account-wide. |
| `twine check` fails, or the page shows raw text | The README has markup PyPI does not render; fix it and rebuild. |
| The figure does not show on PyPI | The public repository does not have `docs/overview.png` on `main` yet: sync it (step 2). PyPI reads the image at view time, so no new upload is needed. |
| A release is broken | *Yank* it on PyPI (*Manage* → *Releases* → *Options* → *Yank*): pip no longer chooses it unless asked for that exact version. Then release a fixed version. Do not delete releases. |

## Changing the example notebooks

Edit them in Jupyter, clear their outputs
(`jupyter nbconvert --clear-output --inplace python/src/wfdbx/examples/*.ipynb`),
and run `pytest python/tests/test_examples.py`.
