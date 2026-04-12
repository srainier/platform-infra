import pulumi
import pulumi_digitalocean as do


def export_all(
    *,
    region: str,
    vpc: do.Vpc,
    postgres_cluster: do.DatabaseCluster,
    postgres_pool: do.DatabaseConnectionPool,
    valkey_cluster: do.DatabaseCluster,
    dns_zone: pulumi.Output[str] | None,
) -> None:
    # Postgres
    pulumi.export("postgres_cluster_id", postgres_cluster.id)
    pulumi.export("postgres_host", postgres_cluster.private_host)
    pulumi.export("postgres_port", postgres_cluster.port)
    pulumi.export("postgres_admin_user", postgres_cluster.user)
    pulumi.export("postgres_admin_password", pulumi.Output.secret(postgres_cluster.password))
    pulumi.export("postgres_connection_pool_host", postgres_pool.private_host)

    # Valkey — exported as redis_* so app repos need no changes
    pulumi.export("redis_host", valkey_cluster.private_host)
    pulumi.export("redis_port", valkey_cluster.port)
    pulumi.export("redis_password", pulumi.Output.secret(valkey_cluster.password))
    pulumi.export("redis_url", pulumi.Output.secret(valkey_cluster.private_uri))

    # Network
    pulumi.export("vpc_id", vpc.id)
    pulumi.export("do_region", region)

    # DNS (None when no domain is configured)
    pulumi.export("dns_zone", dns_zone)
