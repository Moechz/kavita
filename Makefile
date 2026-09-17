# Makefile - 便捷入口（实际逻辑都在 build.sh）
.PHONY: all fetch stage verify deb clean distclean info check

all: package

package:
	./build.sh

fetch:
	./build.sh fetch

stage:
	./build.sh stage

verify:
	./build.sh verify

deb:
	./build.sh deb

clean:
	./build.sh clean

distclean:
	./build.sh distclean

info:
	./build.sh info

# 语法检查
check:
	sh -n makedeb.sh
	bash -n build.sh
	bash -n assets/preinst
	bash -n assets/prerm
	bash -n assets/postrm
	sed -e 's|@VERSION@|0.0.0|g' assets/postinst | bash -n
	python3 -c "import json; json.load(open('assets/config.ini.in'))"
	python3 -c "import json; json.load(open('assets/appsettings-init.json'))"
	python3 scripts/check_assets.py
	@echo "语法检查通过"
