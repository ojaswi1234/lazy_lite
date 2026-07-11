#!/usr/bin/env python3
"""
LeetCode API bridge for lazy_lite (Lite-XL plugin).
Reads JSON commands from stdin, writes JSON responses to stdout.
"""

import sys, os, json, time, re, threading
import urllib.request, urllib.error, ssl

USERDIR = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.config/lite-xl")
SESSION_FILE = os.path.join(USERDIR, "leetcode_session.json")

# ── session ────────────────────────────────────────────────────────────────────
def load_session():
    try:
        with open(SESSION_FILE) as f:
            d = json.load(f)
            return d.get("LEETCODE_SESSION", ""), d.get("csrftoken", ""), d.get("raw", "")
    except Exception:
        return "", "", ""

def save_session(session, csrf, raw=""):
    os.makedirs(USERDIR, exist_ok=True)
    with open(SESSION_FILE, "w") as f:
        json.dump({"LEETCODE_SESSION": session, "csrftoken": csrf, "raw": raw}, f)

# ── HTTP ───────────────────────────────────────────────────────────────────────
_ctx = ssl.create_default_context()
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE

def http_request(url, data=None, method="POST"):
    session, csrf, raw = load_session()
    headers = {
        "Content-Type":   "application/json",
        "Referer":        "https://leetcode.com",
        "User-Agent":     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "x-csrftoken":    csrf,
        "Cookie":         raw if raw else f"LEETCODE_SESSION={session}; csrftoken={csrf}",
    }
    body = json.dumps(data).encode() if data else None
    req  = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=_ctx, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode('utf-8', errors='ignore')
        if e.code == 429:
            raise Exception("Too Many Requests: Please wait 10 seconds before submitting again.")
        elif e.code == 499:
            raise Exception("Error 499: LeetCode dropped the request. Try again.")
        elif e.code == 403:
            raise Exception("403 Forbidden: Your session might be expired. Try re-authenticating.")
        else:
            raise Exception(f"HTTP {e.code}: {e.reason or 'Unknown'}. {body_text[:200]}")

def graphql(query_str, variables=None):
    return http_request("https://leetcode.com/graphql",
                        {"query": query_str, "variables": variables or {}})

def poll(url, interval=1.5, timeout=45):
    """Poll a LeetCode check endpoint until state != STARTED."""
    t0 = time.time()
    while True:
        data = http_request(url, method="GET")
        if data.get("state") != "STARTED":
            return data
        if time.time() - t0 > timeout:
            raise TimeoutError("Judge timed out")
        time.sleep(interval)

# ── HTML stripping ─────────────────────────────────────────────────────────────
def strip_html(html):
    # Preserve some structure before stripping
    html = re.sub(r"<br\s*/?>", "\n", html, flags=re.IGNORECASE)
    html = re.sub(r"</?p\s*/?>", "\n", html, flags=re.IGNORECASE)
    html = re.sub(r"<li\s*/?>", "\n• ", html, flags=re.IGNORECASE)
    html = re.sub(r"<strong>(.*?)</strong>", r"\1", html, flags=re.IGNORECASE|re.DOTALL)
    html = re.sub(r"<code>(.*?)</code>", r"`\1`", html, flags=re.IGNORECASE|re.DOTALL)
    html = re.sub(r"<[^>]+>", "", html)
    html = html.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    html = html.replace("&quot;", '"').replace("&#39;", "'").replace("&nbsp;", " ")
    
    # Clean up trailing spaces (which turns space-only lines into empty lines)
    html = re.sub(r"[ \t]+$", "", html, flags=re.MULTILINE)
    
    # Collapse excessive blank lines
    html = re.sub(r"\n{3,}", "\n\n", html)
    return html.strip()

# ── command handlers ───────────────────────────────────────────────────────────

def cmd_auth_set(params):
    session = params.get("session", "")
    csrf    = params.get("csrf", "")
    raw     = params.get("raw", "")
    save_session(session, csrf, raw)
    result = cmd_auth_check({})
    if not result["ok"]:
        # Revert — don't save bad cookies
        save_session("", "", "")
        return {"ok": False, "error": "Cookies are invalid: " + result.get("error", "")}
    return {"ok": True, "data": result["data"]}

import shutil, tempfile
def auto_get_leetcode_cookies():
    try:
        import browser_cookie3
    except ImportError:
        return None, None, "missing_lib"

    def safe_chrome():
        chrome_path = os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\User Data\Default\Network\Cookies")
        if not os.path.exists(chrome_path):
            chrome_path = os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cookies")
        if not os.path.exists(chrome_path):
            return browser_cookie3.chrome(domain_name=".leetcode.com")
            
        tmp = tempfile.mktemp(suffix=".db")
        shutil.copy2(chrome_path, tmp)
        try:
            return browser_cookie3.chrome(cookie_file=tmp, domain_name=".leetcode.com")
        finally:
            if os.path.exists(tmp):
                try: os.remove(tmp)
                except: pass

    browsers = [
        ("chrome",   safe_chrome),
        ("firefox",  lambda: browser_cookie3.firefox(domain_name=".leetcode.com")),
        ("edge",     lambda: browser_cookie3.edge(domain_name=".leetcode.com")),
        ("brave",    lambda: browser_cookie3.brave(domain_name=".leetcode.com")),
        ("chromium", lambda: browser_cookie3.chromium(domain_name=".leetcode.com")),
    ]
    for name, fn in browsers:
        try:
            cj = fn()
            session, csrf = "", ""
            for cookie in cj:
                if cookie.name == "LEETCODE_SESSION": session = cookie.value
                if cookie.name == "csrftoken":        csrf    = cookie.value
            if session and csrf:
                return session, csrf, name
        except Exception:
            continue
    return None, None, None

def cmd_auth_auto(params):
    session, csrf, browser = auto_get_leetcode_cookies()
    if browser == "missing_lib":
        return {"ok": False, "error": "browser_cookie3 is not installed. Run: pip install browser-cookie3"}
    s, c, _ = auto_get_leetcode_cookies()
    if s and c:
        save_session(s, c)
        return cmd_auth_check({})
    return {"ok": False, "error": "No browser session found"}

def cmd_auth_check(params):
    try:
        res = graphql("query { userStatus { isSignedIn username avatar } }")
        if res and res.get("data", {}).get("userStatus", {}).get("isSignedIn"):
            username = res["data"]["userStatus"]["username"]
            avatar = res["data"]["userStatus"].get("avatar")
            
            GQL2 = """
            query userProfileUserQuestionProgress($userSlug: String!) {
              matchedUser(username: $userSlug) {
                submitStats {
                  acSubmissionNum { difficulty count }
                }
              }
            }"""
            stats = []
            try:
                r2 = graphql(GQL2, {"userSlug": username})
                stats = r2["data"]["matchedUser"]["submitStats"]["acSubmissionNum"]
            except:
                pass
                
            return {"ok": True, "data": {"username": username, "avatar": avatar, "stats": stats}}
        return {"ok": False, "error": "Not signed in"}
    except Exception as e:
        return {"ok": False, "error": f"Network Error: {str(e)}"}

def cmd_problem_list(params):
    difficulty = params.get("difficulty", "ALL")
    skip       = params.get("skip", 0)
    limit      = params.get("limit", 50)
    search     = params.get("search", "").lower()

    topic_tags = []
    companies = []
    keywords = []

    for word in search.split():
        if word.startswith("#") and len(word) > 1:
            topic_tags.append(word[1:])
        elif word.startswith("@") and len(word) > 1:
            companies.append(word[1:])
        else:
            keywords.append(word)

    local_db = {}
    try:
        db_path = os.path.join(USERDIR, "plugins", "company_tags.json")
        if os.path.exists(db_path):
            with open(db_path, "r", encoding="utf-8") as f:
                local_db = json.load(f)
    except Exception:
        pass

    if companies:
        matching_slugs = []
        for slug, tags in local_db.items():
            tags_lower = [t.lower().replace(" ", "-") for t in tags]
            if all(c in tags_lower for c in companies):
                if all(kw in slug for kw in keywords):
                    matching_slugs.append(slug)
        
        total = len(matching_slugs)
        page_slugs = matching_slugs[skip : skip + limit]
        
        if not page_slugs:
            return {"ok": True, "data": {"total": total, "problems": []}}
            
        gql_queries = []
        for i, slug in enumerate(page_slugs):
            gql_queries.append(f'q{i}: question(titleSlug: "{slug}") {{ questionFrontendId title titleSlug difficulty acRate isPaidOnly status }}')
        
        GQL = "query { " + " ".join(gql_queries) + " }"
        
        try:
            r = graphql(GQL)
            if not r or "data" not in r:
                return {"ok": False, "error": "GraphQL query failed"}
                
            problems = []
            for i in range(len(page_slugs)):
                q = r["data"].get(f"q{i}")
                if q:
                    problems.append({
                        "id":         q["questionFrontendId"],
                        "title":      q["title"],
                        "slug":       q["titleSlug"],
                        "difficulty": q["difficulty"],
                        "ac_rate":    round(q.get("acRate") or 0, 1),
                        "paid":       q["isPaidOnly"],
                        "status":     q.get("status"),
                    })
            return {"ok": True, "data": {"total": total, "problems": problems}}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    filters = {}
    if difficulty in ("EASY", "MEDIUM", "HARD"):
        filters["difficulty"] = difficulty
    if keywords:
        filters["searchKeywords"] = " ".join(keywords)
    if topic_tags:
        filters["tags"] = topic_tags

    GQL = """
    query problemsetQuestionList($categorySlug: String, $limit: Int, $skip: Int, $filters: QuestionListFilterInput) {
      problemsetQuestionList: questionList(categorySlug: $categorySlug limit: $limit skip: $skip filters: $filters) {
        total: totalNum
        questions: data { questionFrontendId title titleSlug difficulty acRate isPaidOnly status }
      }
    }"""
    try:
        r = graphql(GQL, {"categorySlug": "", "limit": limit, "skip": skip, "filters": filters})
        if not r or "data" not in r:
            return {"ok": False, "error": "GraphQL query failed or returned no data"}
            
        plist = r["data"]["problemsetQuestionList"]
        return {"ok": True, "data": {
            "total": plist["total"],
            "problems": [
                {
                    "id":         q["questionFrontendId"],
                    "title":      q["title"],
                    "slug":       q["titleSlug"],
                    "difficulty": q["difficulty"],
                    "ac_rate":    round(q.get("acRate") or 0, 1),
                    "paid":       q["isPaidOnly"],
                    "status":     q.get("status"),
                }
                for q in plist["questions"]
            ]
        }}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def cmd_daily_challenge(params):
    GQL = """
    query {
      activeDailyCodingChallengeQuestion {
        question { titleSlug }
      }
    }"""
    try:
        r = graphql(GQL)
        slug = r["data"]["activeDailyCodingChallengeQuestion"]["question"]["titleSlug"]
        return {"ok": True, "data": {"slug": slug}}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def cmd_problem_detail(params):
    slug = params.get("slug", "")
    GQL  = """
    query questionData($titleSlug: String!) {
      question(titleSlug: $titleSlug) {
        questionId title titleSlug content difficulty isPaidOnly
        topicTags { name }
        companyTagStats
        similarQuestions
        codeSnippets { lang langSlug code }
        exampleTestcaseList sampleTestCase
      }
    }"""
    try:
        r = graphql(GQL, {"titleSlug": slug})
        q = r["data"]["question"]
        
        similar_qs = []
        try:
            sq_str = q.get("similarQuestions")
            if sq_str:
                similar_qs = json.loads(sq_str)
        except Exception:
            pass

        q = r["data"]["question"]
        starters = {s["langSlug"]: s["code"] for s in (q.get("codeSnippets") or [])}
        test_cases = "\n".join(q.get("exampleTestcaseList") or [q.get("sampleTestCase", "")])
        
        content = q.get("content")
        if not content and q.get("isPaidOnly"):
            content = "<h3>Premium Required</h3><p>This problem is exclusively for LeetCode Premium users. You must purchase a subscription on LeetCode to view this question's details and submit code.</p>"
            
        topics = [t["name"] for t in (q.get("topicTags") or [])]
        companies = []
        
        # Override with local offline JSON dataset to bypass Premium!
        try:
            local_json_path = os.path.join(USERDIR, "plugins", "company_tags.json")
            if os.path.exists(local_json_path):
                with open(local_json_path, "r", encoding="utf-8") as f:
                    local_db = json.load(f)
                    if slug in local_db:
                        companies = local_db[slug]
        except Exception:
            pass

        # Fallback to Premium tags if available and not found locally
        if not companies:
            c_stats = q.get("companyTagStats")
            if c_stats:
                try:
                    c_data = json.loads(c_stats)
                    for stage in c_data.values():
                        for c in stage:
                            if c.get("name") and c["name"] not in companies:
                                companies.append(c["name"])
                except:
                    pass
                
        return {"ok": True, "data": {
            "question_id":   q["questionId"],
            "title":         q["title"],
            "slug":          q["titleSlug"],
            "difficulty":    q["difficulty"],
            "content_plain": strip_html(content or ""),
            "starters":      starters,
            "test_cases":    test_cases,
            "topics":        topics,
            "companies":     companies,
            "similar_questions": similar_qs,
        }}
    except Exception as e:
        return {"ok": False, "error": str(e)}

STATUS_MAP = {
    10: "Accepted", 11: "Wrong Answer", 12: "Memory Limit Exceeded",
    13: "Output Limit Exceeded", 14: "Time Limit Exceeded",
    15: "Runtime Error", 16: "Internal Error", 20: "Compile Error",
}

def cmd_run_code(params):
    slug        = params.get("slug")
    question_id = params.get("question_id")
    lang        = params.get("lang", "python3")
    code        = params.get("code", "")
    test_input  = params.get("test_input", "")
    try:
        r = http_request(
            f"https://leetcode.com/problems/{slug}/interpret_solution/",
            {"lang": lang, "question_id": question_id,
             "typed_code": code, "data_input": test_input}
        )
        interpret_id = r.get("interpret_id")
        if not interpret_id:
            return {"ok": False, "error": "No interpret_id returned: " + str(r)}
        result = poll(f"https://leetcode.com/submissions/detail/{interpret_id}/check/",
                      interval=1.5, timeout=30)
        sc = result.get("status_code", 0)
        ok = sc == 10
        return {
            "ok": ok,
            "data": {
                "status":           STATUS_MAP.get(sc, result.get("status_msg", "Unknown")),
                "status_code":      sc,
                "total_correct":    result.get("correct_answer", False) and 1 or 0,
                "total_testcases":  1,
                "runtime":          result.get("status_runtime", "N/A"),
                "memory":           result.get("status_memory", "N/A"),
                "code_output":      result.get("code_output", []),
                "expected_output":  result.get("expected_output", []),
                "std_output":       result.get("std_output", ""),
                "compile_error":    result.get("compile_error", ""),
                "runtime_error":    result.get("runtime_error", ""),
            },
            "error": None if ok else STATUS_MAP.get(sc, "Error"),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}

def cmd_submit(params):
    slug        = params.get("slug")
    question_id = params.get("question_id")
    lang        = params.get("lang", "python3")
    code        = params.get("code", "")
    try:
        r = http_request(
            f"https://leetcode.com/problems/{slug}/submit/",
            {"lang": lang, "question_id": question_id, "typed_code": code}
        )
        sub_id = r.get("submission_id")
        if not sub_id:
            return {"ok": False, "error": "No submission_id returned: " + str(r)}
        result = poll(f"https://leetcode.com/submissions/detail/{sub_id}/check/",
                      interval=2.0, timeout=45)
        sc = result.get("status_code", 0)
        ok = sc == 10
        return {
            "ok": ok,
            "data": {
                "status":               STATUS_MAP.get(sc, result.get("status_msg", "Unknown")),
                "status_code":          sc,
                "runtime":              result.get("status_runtime", "N/A"),
                "runtime_percentile":   result.get("runtime_percentile", 0),
                "memory":               result.get("status_memory", "N/A"),
                "memory_percentile":    result.get("memory_percentile", 0),
                "total_correct":        result.get("total_correct", 0),
                "total_testcases":      result.get("total_testcases", 0),
                "submission_id":        sub_id,
                "compile_error":        result.get("compile_error", ""),
                "runtime_error":        result.get("runtime_error", ""),
            },
            "error": None if ok else STATUS_MAP.get(sc, "Error"),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}

# ── main loop ──────────────────────────────────────────────────────────────────
HANDLERS = {
    "auth_check":      cmd_auth_check,
    "auth_set":        cmd_auth_set,
    "auth_auto":       cmd_auth_auto,
    "problem_list":    cmd_problem_list,
    "problem_detail":  cmd_problem_detail,
    "run_code":        cmd_run_code,
    "submit":          cmd_submit,
    "daily_challenge": cmd_daily_challenge,
}

def to_lua(obj):
    if isinstance(obj, bool): return "true" if obj else "false"
    if obj is None: return "nil"
    if isinstance(obj, (int, float)): return str(obj)
    if isinstance(obj, str): return json.dumps(obj, ensure_ascii=False)
    if isinstance(obj, list):
        return "{" + ", ".join(to_lua(x) for x in obj) + "}"
    if isinstance(obj, dict):
        return "{" + ", ".join(f"[{to_lua(k)}]={to_lua(v)}" for k, v in obj.items()) + "}"
    return "nil"

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding='utf-8')
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        try:
            params = json.loads(line)
            cmd    = params.get("cmd", "")
            req_id = params.get("id", "")
            handler = HANDLERS.get(cmd)
            if handler:
                result = handler(params)
            else:
                result = {"ok": False, "error": f"Unknown command: {cmd}"}
            result["id"] = req_id
            print(to_lua(result), flush=True)
        except Exception as e:
            print(to_lua({"id": "", "ok": False, "error": str(e)}), flush=True)
