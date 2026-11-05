FROM ghcr.io/openclaw/openclaw:2026.10.9

# 官方 amd64 套件；更新時一起核對版本與 SHA256。
USER root
RUN test "$(dpkg --print-architecture)" = amd64 \
    && curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 \
       https://cli.github.com/packages/pool/main/g/gh/gh_2.103.3_amd64.deb \
       -o /tmp/gh.deb \
    && printf '%s\n' 'e3bafef96328d1a67de3a968bdfe1cc2ffd58cf6aba8b5e201356897ed06bb3d  /tmp/gh.deb' | sha256sum -c - \
    && dpkg -i /tmp/gh.deb \
    && rm /tmp/gh.deb

USER node
RUN gh --version
