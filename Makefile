APP      = TSVee
CONFIG   = release
BINARY   = .build/$(CONFIG)/$(APP)
BUNDLE   = dist/$(APP).app

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE)

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist
