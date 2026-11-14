# Steep checks lib/ against sig/generated/, which rbs-inline writes from the
# comments in lib/. sig-deps/ holds what those comments cannot say: stubs of
# the gems that ship no signatures, and corrections to the stdlib ones. It
# stays out of the gem, so a user never gets another gem's types from it.
target :lib do
  signature "sig", "sig-deps"
  check "lib"

  library "hegeltest", "json", "fileutils", "open3", "tmpdir", "erb", "yaml", "prism", "optparse", "time", "digest", "date", "coverage", "etc", "timeout", "socket"
end
