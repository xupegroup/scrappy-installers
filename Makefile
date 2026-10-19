# Scrappy worker autoinstall ISO — build in Docker (works on WSL2).
#
#   make iso          build out/scrappy-worker-24.04.5-<git-sha>.iso
#   make lint         shellcheck + render/grub checks, no ISO download
#   make passwd-hash  prompt for a password, print its yescrypt hash
#   make clean        remove work dirs and built ISOs (keeps the download cache)

IMAGE   := scrappy-iso-builder
GIT_REV := $(shell git rev-parse --short HEAD)$(shell test -z "$$(git status --porcelain)" || echo -dirty)

DOCKER_RUN = docker run --rm \
	--user $(shell id -u):$(shell id -g) -e HOME=/tmp -e GIT_REV=$(GIT_REV) \
	-v $(CURDIR):/src:ro -v $(CURDIR)/build:/build -v $(CURDIR)/out:/out \
	$(IMAGE)

.PHONY: image iso lint passwd-hash clean

image:
	docker build -q -t $(IMAGE) iso >/dev/null

iso: image
	mkdir -p build out
	$(DOCKER_RUN) bash /src/iso/build.sh iso

lint: image
	mkdir -p build out
	$(DOCKER_RUN) bash /src/iso/build.sh lint

passwd-hash: image
	docker run --rm -it $(IMAGE) mkpasswd -m yescrypt

clean:
	rm -rf build/work build/lint out
