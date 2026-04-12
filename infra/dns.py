import pulumi


def create_dns_zone(domain: str) -> pulumi.Output[str] | None:
    # DNS zone provisioning is disabled until a domain is configured.
    # To enable: create a do.Domain resource here and return its name output.
    # Set platform-infra:domain in Pulumi.<stack>.yaml to activate.
    if domain:
        raise NotImplementedError("DNS zone provisioning not yet implemented")
    return None
