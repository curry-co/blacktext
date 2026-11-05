CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer

# With only the Command Line Tools installed, Swift Testing lives outside SwiftPM's default search paths.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
	-Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib
endif

.PHONY: build app run install uninstall test bench icon clean

build:
	swift build -c release

app:
	scripts/build-app.sh

run: app
	open build/BlackText.app

install: app
	scripts/install.sh

uninstall:
	rm -rf ~/Applications/BlackText.app
	rm -f ~/.local/bin/blacktext

test:
	swift test $(TEST_FLAGS)

bench:
	scripts/bench.sh

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build
