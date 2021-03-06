package: Python
version: "%(tag_basename)s"
tag: alice/v2.7.10
source: https://github.com/alisw/cpython.git
requires:
 - AliEn-Runtime:(?!.*ppc64)
 - FreeType
 - libpng
 - sqlite
build_requires:
 - curl
env:
  SSL_CERT_FILE: "$(export PATH=$PYTHON_ROOT/bin:$PATH; export LD_LIBRARY_PATH=$PYTHON_ROOT/lib:$LD_LIBRARY_PATH; python -c \"import certifi; print certifi.where()\")"
  PYTHONHOME: "$PYTHON_ROOT"
prefer_system: (?!slc5)
prefer_system_check:
  python -c 'import sys; import sqlite3; sys.exit(1 if sys.version_info < (2, 7) else 0)' && pip --help > /dev/null && printf '#include "pyconfig.h"' | gcc -c $(python-config --includes) -xc -o /dev/null -; if [ $? -ne 0 ]; then printf "Python, the Python development packages, and pip must be installed on your system.\nUsually those packages are called python, python-devel (or python-dev) and python-pip.\n"; exit 1; fi
---
#!/bin/bash -ex

case $ARCHITECTURE in
  slc5*) ;;
  *)
    echo "Building our own Python. If you want to avoid this please install Python >= 2.7."
  ;;
esac

rsync -av --exclude '**/.git' $SOURCEDIR/ $BUILDDIR/

# The only way to pass externals to Python
LDFLAGS=
CPPFLAGS=
for ext in $ALIEN_RUNTIME_ROOT $ZLIB_ROOT $FREETYPE_ROOT $LIBPNG_ROOT $SQLITE_ROOT; do
  LDFLAGS="$(find $ext -type d -name lib -exec echo -L\{\} \;) $LDFLAGS"
  CPPFLAGS="$(find $ext -type d -name include -exec echo -I\{\} \;) $CPPFLAGS"
done
export LDFLAGS=$(echo $LDFLAGS)
export CPPFLAGS=$(echo $CPPFLAGS)

# OpenSSL and zlib from AliEn?
if [[ $ALIEN_RUNTIME_VERSION ]]; then
  OPENSSL_ROOT=${OPENSSL_ROOT:+$ALIEN_RUNTIME_ROOT}
  ZLIB_ROOT=${ZLIB_ROOT:+$ALIEN_RUNTIME_ROOT}
fi

# Set own OpenSSL if appropriate
if [[ $OPENSSL_ROOT ]]; then
  export CPATH="$OPENSSL_ROOT/include:$OPENSSL_ROOT/include/openssl:$CPATH"
  export CPPFLAGS="-I$OPENSSL_ROOT/include -I$OPENSSL_ROOT/include/openssl $CPPFLAGS"
  export CFLAGS="-I$OPENSSL_ROOT/include -I$OPENSSL_ROOT/include/openssl"
  cat >> Modules/Setup.dist <<EOF

SSL=$OPENSSL_ROOT
_ssl _ssl.c \
        -DUSE_SSL -I\$(SSL)/include -I\$(SSL)/include/openssl \
        -L\$(SSL)/lib -lssl -lcrypto
EOF

fi

./configure --prefix=$INSTALLROOT \
            --enable-shared       \
            --with-system-expat   \
            --enable-unicode=ucs4
make  # no multicore
make install

# Install pip
cd $BUILDDIR
export PATH=$INSTALLROOT/bin:$PATH
export LD_LIBRARY_PATH=$INSTALLROOT/lib:$LD_LIBRARY_PATH
export DYLD_LIBRARY_PATH=$INSTALLROOT/lib:$DYLD_LIBRARY_PATH
for U in https://bootstrap.pypa.io/get-pip.py \
         https://raw.githubusercontent.com/pypa/get-pip/master/get-pip.py; do
  curl -kSsL -o get-pip.py $U || continue && break
done
python get-pip.py
python "$INSTALLROOT/bin/pip" install -U pip

# Remove long shebangs (by default max is 128 chars on Linux)
pushd "$INSTALLROOT/bin"
  sed -i.deleteme -e "1 s|^#!${INSTALLROOT}/bin/\(.*\)$|#!/usr/bin/env \1|" * || true
  rm -f *.deleteme
popd

# Remove useless stuff
rm -rvf $INSTALLROOT/share \
       $INSTALLROOT/lib/python*/test
find $INSTALLROOT/lib/python* \
     -mindepth 2 -maxdepth 2 -type d -and \( -name test -or -name tests \) \
     -exec rm -rvf '{}' \;

# Execute some commands in a clean environment
cat > $INSTALLROOT/bin/yum-cleanenv <<'EOF'
#!/bin/bash
exec env -i /usr/bin/"$(basename "$0")" "$@"
EOF
chmod +x $INSTALLROOT/bin/yum-cleanenv
for F in $(echo /usr/bin/yum*) $(echo /usr/bin/rpm*); do
  [[ -e $F ]] || continue
  ln -nfs yum-cleanenv $INSTALLROOT/bin/"$(basename "$F")"
done

# Get OpenSSL and zlib at runtime from AliEn-Runtime if appropriate
[[ $ALIEN_RUNTIME_VERSION ]] && unset OPENSSL_VERSION ZLIB_VERSION

# Modulefile
MODULEDIR="$INSTALLROOT/etc/modulefiles"
MODULEFILE="$MODULEDIR/$PKGNAME"
mkdir -p "$MODULEDIR"
cat > "$MODULEFILE" <<EoF
#%Module1.0
proc ModulesHelp { } {
  global version
  puts stderr "ALICE Modulefile for $PKGNAME $PKGVERSION-@@PKGREVISION@$PKGHASH@@"
}
set version $PKGVERSION-@@PKGREVISION@$PKGHASH@@
module-whatis "ALICE Modulefile for $PKGNAME $PKGVERSION-@@PKGREVISION@$PKGHASH@@"
# Dependencies
module load BASE/1.0 ${ALIEN_RUNTIME_VERSION:+AliEn-Runtime/$ALIEN_RUNTIME_VERSION-$ALIEN_RUNTIME_REVISION} \\
                     ${ZLIB_VERSION:+zlib/$ZLIB_VERSION-$ZLIB_REVISION}                                     \\
                     ${OPENSSL_VERSION:+OpenSSL/$OPENSSL_VERSION-$OPENSSL_REVISION}                         \\
                     ${LIBPNG_VERSION:+libpng/$LIBPNG_VERSION-$LIBPNG_REVISION}                             \\
                     ${FREETYPE_VERSION:+FreeType/$FREETYPE_VERSION-$FREETYPE_REVISION}
# Our environment
setenv PYTHON_ROOT \$::env(BASEDIR)/$PKGNAME/\$version
setenv PYTHONHOME \$::env(BASEDIR)/$PKGNAME/\$version
prepend-path PATH $::env(PYTHON_ROOT)/bin
prepend-path LD_LIBRARY_PATH $::env(PYTHON_ROOT)/lib
$([[ ${ARCHITECTURE:0:3} == osx ]] && echo "prepend-path DYLD_LIBRARY_PATH $::env(PYTHON_ROOT)/lib")
EoF
