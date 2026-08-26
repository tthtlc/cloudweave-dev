##set -x
LIBCLOUD_NTNX_USER=cy-user01 LIBCLOUD_NTNX_PASSWORD="P@ssw0rd" ./test_read.sh --target real --version v4.2 ###--verbose
LIBCLOUD_NTNX_USER="cy-user01" LIBCLOUD_NTNX_PASSWORD="P@ssw0rd" ./test_write.sh --target real --version v4.2 ###--verbose
LIBCLOUD_NTNX_USER=cy-user01 LIBCLOUD_NTNX_PASSWORD="P@ssw0rd" ./test_read.sh --target real --version v4.2 --verbose
