APP      = TSVee
CONFIG   = release
BINARY   = .build/$(CONFIG)/$(APP)
BUNDLE   = dist/$(APP).app
ICON_SRC = Support/tsvee_icon.png
ICONSET  = .build/$(APP).iconset
ICNS     = .build/$(APP).icns

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIG)

# The .icns is generated from the 1024px source art rather than checked in, so
# the artwork stays the one thing to edit.
$(ICNS): $(ICON_SRC)
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size $(ICON_SRC) --out $(ICONSET)/icon_$${size}x$${size}.png >/dev/null; \
		sips -z $$(($$size * 2)) $$(($$size * 2)) $(ICON_SRC) \
			--out $(ICONSET)/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)
	rm -rf $(ICONSET)

bundle: build $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE)

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist
