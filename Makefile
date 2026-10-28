.PHONY: all build test app run install clean

all: app

build:
	swift build

test:
	swift build
	.build/debug/UtilizationAnalyzer --self-test

app:
	chmod +x scripts/bundle_app.sh
	./scripts/bundle_app.sh

run: app
	open dist/UtilizationAnalyzer.app

install: app
	rm -rf /Applications/UtilizationAnalyzer.app
	cp -R dist/UtilizationAnalyzer.app /Applications/UtilizationAnalyzer.app
	@echo "Installed to /Applications/UtilizationAnalyzer.app"

clean:
	swift package clean
	rm -rf .build dist
