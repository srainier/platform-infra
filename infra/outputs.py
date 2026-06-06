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
    # Private host: only reachable from inside the VPC (Droplets, etc.).
    pulumi.export("postgres_host", postgres_cluster.private_host)
    # Public host: what App Platform apps (not VPC members) must use, gated by
    # trusted sources. Prefer this from app repos.
    pulumi.export("postgres_host_public", postgres_cluster.host)
    pulumi.export("postgres_port", postgres_cluster.port)
    pulumi.export("postgres_admin_user", postgres_cluster.user)
    pulumi.export("postgres_connection_pool_host", postgres_pool.private_host)
    pulumi.export("postgres_connection_pool_host_public", postgres_pool.host)
    # NOTE: postgres_admin_password is deliberately NOT exported. App-owners have
    # Read on this stack for StackReference; no secret may be exported. The admin
    # onboarding script reads doadmin creds directly from the DO API.

    # Valkey — exported as redis_* so app repos need no changes
    pulumi.export("redis_host", valkey_cluster.private_host)
    pulumi.export("redis_host_public", valkey_cluster.host)
    pulumi.export("redis_port", valkey_cluster.port)
    pulumi.export("redis_password", pulumi.Output.secret(valkey_cluster.password))
    # Public URI: App Platform cannot reach the private Valkey host.
    pulumi.export("redis_url", pulumi.Output.secret(valkey_cluster.uri))
    pulumi.export("redis_url_private", pulumi.Output.secret(valkey_cluster.private_uri))

    # Network
    pulumi.export("vpc_id", vpc.id)
    pulumi.export("do_region", region)

    # DNS (None when no domain is configured)
    pulumi.export("dns_zone", dns_zone)
