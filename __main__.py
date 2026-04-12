import pulumi

from infra import dns, networking, outputs, postgres, valkey

config = pulumi.Config()
region: str = config.require("do_region")
pg_version: str = config.require("postgres_version")
pg_size: str = config.require("postgres_size")
valkey_size: str = config.require("valkey_size")
domain: str = config.get("domain") or ""

vpc = networking.create_vpc(region)
_project = networking.create_project()

pg_cluster, pg_pool = postgres.create_postgres(region, pg_version, pg_size, vpc.id)
valkey_cluster = valkey.create_valkey(region, valkey_size, vpc.id)
dns_zone = dns.create_dns_zone(domain)

outputs.export_all(
    region=region,
    vpc=vpc,
    postgres_cluster=pg_cluster,
    postgres_pool=pg_pool,
    valkey_cluster=valkey_cluster,
    dns_zone=dns_zone,
)
