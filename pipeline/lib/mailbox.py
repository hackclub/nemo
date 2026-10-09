GMAIL_DOMAINS = ("gmail.com", "googlemail.com")


def mailbox(email):
    local, at, domain = (email or "").strip().lower().rpartition("@")
    if not at or not domain:
        return None
    local = local.split("+", 1)[0]
    if domain in GMAIL_DOMAINS:
        domain = GMAIL_DOMAINS[0]
        local = local.replace(".", "")
    if not local:
        return None
    return f"{local}@{domain}"


def staff_domain(domain, staff):
    return any(domain == one or domain.endswith(f".{one}") for one in staff)
