write down some test in a script which I can used to test that the docker  openfga-postgres, openfga container is working corrrectly using curl mainly.
use stoplight_mock_test.md as the example for a common testing infrastructure.



        identity-service
f90b0f4cf0d0   server-portal                      "/docker-entrypoint.…"   36 hours ago   Up 36 hours             80/tcp, 0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp                                                            portal
043bd3c4b680   swaggerapi/swagger-ui:v5.18.2      "/docker-entrypoint.…"   6 days ago     Up 6 days               80/tcp, 0.0.0.0:9898->8080/tcp, [::]:9898->8080/tcp                                                            libcloud-swagger-ui
ec3ca4cc95bd   openfga-local:latest               "/openfga run --data…"   7 days ago     Up 2 days (healthy)     0.0.0.0:2112->2112/tcp, [::]:2112->2112/tcp, 0.0.0.0:8080-8081->8080-8081/tcp, [::]:8080-8081->8080-8081/tcp   openfga
d5c61202832d   postgres:16                        "docker-entrypoint.s…"   7 days ago     Up 7 days (healthy)     0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp                                                                    openfga-postgres
7469abc9d9e9   ghcr.io/dexidp/dex:v2.41.1         "/usr/local/bin/dock…"   7 days ago     Up 13 hours (healthy)   0.0.0.0:5556->5556/tcp, [::]:5556->5556/tcp                                                                    dex
2c680020ec84   lldap/lldap:latest                 "tini -- /docker-ent…"   4 weeks ago    Up 3 weeks (healthy)    0.0.0.0:3890->3890/tcp, [::]:3890->3890/tcp, 0.0.0.0:17170->17170/tcp, [::]:17170->17170/tcp                   lldap
61946a99820c   hashicorp/vault:1.15               "docker-entrypoint.s…"   4 weeks ago    Up 3 weeks (healthy)    0.0.0.0:8200->8200/tcp, [::]:8200->8200/tcp                                                                    vault

