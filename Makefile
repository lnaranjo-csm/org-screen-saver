.PHONY: build app test install release clean
build:
	swift build -c release
app:
	./scripts/build-app-bundle.sh
test:
	swift test
install:
	./install.sh
release:
	./scripts/package-release.sh
clean:
	rm -rf .build dist
