# Local verification target used by `aimee git verify`.
# smoothiso is pure shell; verify-local syntax-checks the installer scripts.
.PHONY: verify-local
verify-local:
	bash -n build-iso.sh
	bash -n installer.sh
	bash -n firstboot.sh
