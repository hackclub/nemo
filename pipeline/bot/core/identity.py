def ensure_member(conn, user_id):
    if not user_id:
        return None
    conn.execute(
        "INSERT INTO fd.member (user_id) VALUES (%s) ON CONFLICT (user_id) DO NOTHING",
        (user_id,),
    )
    return user_id
