# Maintenance Requirements

- After every code change, run the relevant verification, commit the changes, and push them to this repository on GitHub.
- Validate the relevant APP states and interactions locally according to the scope of the changes. GitHub builds must only compile the APP, validate the package, and publish it. Do not run tests, install test dependencies, or provide test switches in GitHub builds. Run relevant tests locally according to the scope of the changes.
- Wait for the GitHub Actions build and APP release corresponding to the pushed commit to succeed. Include a direct APP download link and a link to the build results when replying to the user.
- Confirm that the download package corresponds to the current commit. If the build or release fails, continue addressing the failure and report its actual status. Do not present an older package as the result of the current changes.
- Use a fresh, isolated working directory for testing. Do not modify the original workspace or bypass macOS security mechanisms.
- Keep only downloads, build status, and source build instructions in the README.

- Use localization resources consistently for interface translations. Store the language preference independently of the working directory. Switching languages must not recreate tasks or clear user input.
- All text written by the APP itself to log files must be in English. Preserve user input, model output, and third-party logs in their original form.
