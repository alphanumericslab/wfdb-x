# Releasing the Python package on PyPI

The PyPI project `wfdb-x` is built from this directory (`python/`) of the
wfdb-x repository. The distributions contain the `wfdbx` package, its sample
data (`src/wfdbx/sample_data`) and example notebooks (`src/wfdbx/examples`);
the source distribution also contains the unit tests, which skip the tests
that need the repository's test records.

1. Set the version in `src/wfdbx/__init__.py` (`__version__`; PEP 440, e.g.
   `1.0.1` or `1.1.0`; `.devN`, `aN`, `bN`, `rcN` are pre-releases, which
   `pip install wfdb-x` does not choose by default). wfdb-x has its own
   version numbers (see *Versions* in the project README), independent of
   the WFDB version it implements.
2. Run the tests from the repository root, notebooks included:

   ```sh
   pip install -e "./python[test,examples]"
   pytest python/tests
   ```

3. Build and check the distributions:

   ```sh
   cd python
   rm -rf dist
   python -m build                 # pip install build twine
   twine check dist/*
   ```

4. Optionally, test the wheel in a fresh environment
   (`pip install "dist/wfdb_x-<version>-py3-none-any.whl[test]"`, then
   `wfdbx --examples ex` and `pytest` on a copy of `tests/`), and upload to
   TestPyPI first (`twine upload --repository testpypi dist/*`).
5. Upload: `twine upload dist/*`, then tag the release in git
   (`git tag python-v<version>`, `git push origin python-v<version>`).

To change the notebooks, edit them in Jupyter, clear their outputs
(`jupyter nbconvert --clear-output --inplace src/wfdbx/examples/*.ipynb`),
and run `pytest python/tests/test_examples.py`.
