"""WebDAV 来源示例插件。"""

import base64
import email.utils
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from macview_plugin import Plugin

plugin = Plugin()


def _auth_headers(values):
    user = values.get("user") or ""
    password = values.get("password") or ""
    if not user and not password:
        return {}
    token = base64.b64encode("{}:{}".format(user, password).encode("utf-8")).decode("ascii")
    return {"Authorization": "Basic " + token}


def _target_url(base_url, path):
    base = base_url.rstrip("/") + "/"
    if not path:
        return base
    encoded = "/".join(urllib.parse.quote(segment, safe="") for segment in path)
    return base + encoded + "/"


def _local_name(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _find_child(elem, name):
    for child in elem:
        if _local_name(child.tag) == name:
            return child
    return None


@plugin.source_list("webdav")
def list_webdav(source, path):
    values = source.get("values") or {}
    base_url = (values.get("url") or "").strip()
    if not base_url:
        raise ValueError("缺少 WebDAV 地址")
    url = _target_url(base_url, path)
    headers = _auth_headers(values)
    req_headers = dict(headers)
    req_headers["Depth"] = "1"
    req = urllib.request.Request(url, method="PROPFIND", headers=req_headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read()

    root = ET.fromstring(body)
    req_path = urllib.parse.unquote(urllib.parse.urlsplit(url).path).rstrip("/")
    entries = []
    for response in root:
        if _local_name(response.tag) != "response":
            continue
        href_elem = _find_child(response, "href")
        if href_elem is None or not href_elem.text:
            continue
        href = href_elem.text.strip()
        full_url = urllib.parse.urljoin(url, href)
        item_path = urllib.parse.unquote(urllib.parse.urlsplit(full_url).path).rstrip("/")
        if item_path == req_path:
            continue
        name = item_path.rsplit("/", 1)[-1]
        if not name:
            continue

        is_dir = href.endswith("/")
        size = None
        modified = None
        etag = None
        for propstat in response:
            if _local_name(propstat.tag) != "propstat":
                continue
            prop = _find_child(propstat, "prop")
            if prop is None:
                continue
            res_type = _find_child(prop, "resourcetype")
            if res_type is not None and _find_child(res_type, "collection") is not None:
                is_dir = True
            length_elem = _find_child(prop, "getcontentlength")
            if length_elem is not None and length_elem.text:
                try:
                    size = int(length_elem.text.strip())
                except ValueError:
                    pass
            mod_elem = _find_child(prop, "getlastmodified")
            if mod_elem is not None and mod_elem.text:
                try:
                    modified = email.utils.parsedate_to_datetime(mod_elem.text.strip()).timestamp()
                except Exception:
                    pass
            etag_elem = _find_child(prop, "getetag")
            if etag_elem is not None and etag_elem.text:
                etag = etag_elem.text.strip().strip('"')

        item = {"name": name, "kind": "directory" if is_dir else "file"}
        if size is not None:
            item["size"] = size
        if modified is not None:
            item["modified"] = modified
        if etag:
            item["etag"] = etag
        if not is_dir:
            item["url"] = full_url
            if headers:
                item["headers"] = headers
        entries.append(item)
    return entries


if __name__ == "__main__":
    plugin.run()
