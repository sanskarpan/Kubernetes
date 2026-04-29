## Summary

<!--
What changed and why? Provide context for reviewers.
- What problem does this solve?
- What is the approach taken?
-->

## Type of Change

<!-- Mark all that apply with an [x] -->

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Documentation update
- [ ] Refactor (no functional changes, code cleanup)
- [ ] CI / tooling change

## Related Issues

<!--
Link issues that this PR closes or relates to.
Use "Closes #xxx" to auto-close the issue when the PR merges.
-->

Closes #

## Checklist

<!-- All items must be checked before merging. -->

- [ ] `yamllint` passes locally (or no YAML files changed)
- [ ] `kubeconform` passes locally (or no manifests changed)
- [ ] `helm lint` passes locally (or no Helm charts changed)
- [ ] Manifests tested locally (e.g., `kubectl apply --dry-run=server`)
- [ ] Documentation updated (README, inline comments, runbooks)

## Screenshots / Logs

<!--
Paste relevant terminal output, `kubectl describe` output,
or screenshots that help reviewers verify the change.
-->

<details>
<summary>Output</summary>

```
# paste output here
```

</details>
