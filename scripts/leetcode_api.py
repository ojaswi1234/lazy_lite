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
            return d.get("LEETCODE_SESSION", ""), d.get("csrftoken", "")
    except Exception:
        return "", ""

def save_session(session, csrf):
    os.makedirs(USERDIR, exist_ok=True)
    with open(SESSION_FILE, "w") as f:
        json.dump({"LEETCODE_SESSION": session, "csrftoken": csrf}, f)

# ── HTTP ───────────────────────────────────────────────────────────────────────
_ctx = ssl.create_default_context()

def http_request(url, data=None, method="POST"):
    session, csrf = load_session()
    headers = {
        "Content-Type":   "application/json",
        "Referer":        "https://leetcode.com",
        "User-Agent":     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "x-csrftoken":    csrf,
        "Cookie":         f"LEETCODE_SESSION={session}; csrftoken={csrf}",
    }
    body = json.dumps(data).encode() if data else None
    req  = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, context=_ctx, timeout=15) as r:
        return json.loads(r.read().decode())

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
    # Collapse excessive blank lines
    html = re.sub(r"\n{3,}", "\n\n", html)
    return html.strip()

# ── command handlers ───────────────────────────────────────────────────────────
def cmd_auth_check(params):
    try:
        data = http_request("https://leetcode.com/api/problems/all/", method="GET")
        uname = data.get("user_name", "")
        if not uname:
            return {"ok": False, "error": "Not logged in"}
        return {"ok": True, "data": {"username": uname}}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def cmd_auth_set(params):
    session = params.get("session", "")
    csrf    = params.get("csrf", "")
    save_session(session, csrf)
    result = cmd_auth_check({})
    if not result["ok"]:
        # Revert — don't save bad cookies
        save_session("", "")
        return {"ok": False, "error": "Cookies are invalid: " + result.get("error", "")}
    return {"ok": True, "data": result["data"]}

def cmd_problem_list(params):
    skip       = params.get("skip", 0)
    limit      = params.get("limit", 50)
    difficulty = params.get("difficulty", "")
    search     = params.get("search", "")

    filters = {}
    if difficulty in ("EASY", "MEDIUM", "HARD"):
        filters["difficulty"] = difficulty
    if search.strip():
        filters["searchKeywords"] = search.strip()

    GQL = """
    query problemsetQuestionList($categorySlug: String, $limit: Int, $skip: Int, $filters: QuestionListFilterInput) {
      problemsetQuestionList: questionList(
        categorySlug: $categorySlug limit: $limit skip: $skip filters: $filters
      ) {
        total: totalNum
        questions: data {
          questionFrontendId title titleSlug difficulty acRate isPaidOnly
        }
      }
    }"""
    try:
        r = graphql(GQL, {"categorySlug": "", "limit": limit, "skip": skip, "filters": filters})
        plist = r["data"]["problemsetQuestionList"]
        return {"ok": True, "data": {
            "total": plist["total"],
            "problems": [
                {
                    "id":         q["questionFrontendId"],
                    "title":      q["title"],
                    "slug":       q["titleSlug"],
                    "difficulty": q["difficulty"],
                    "ac_rate":    round(q["acRate"], 1),
                    "paid":       q["isPaidOnly"],
                }
                for q in plist["questions"]
            ]
        }}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def cmd_problem_detail(params):
    slug = params.get("slug", "")
    GQL  = """
    query questionData($titleSlug: String!) {
      question(titleSlug: $titleSlug) {
        questionId title titleSlug content difficulty
        codeSnippets { lang langSlug code }
        exampleTestcaseList sampleTestCase
      }
    }"""
    try:
        r = graphql(GQL, {"titleSlug": slug})
        q = r["data"]["question"]
        starters = {s["langSlug"]: s["code"] for s in (q.get("codeSnippets") or [])}
        test_cases = "\n".join(q.get("exampleTestcaseList") or [q.get("sampleTestCase", "")])
        return {"ok": True, "data": {
            "question_id":   q["questionId"],
            "title":         q["title"],
            "slug":          q["titleSlug"],
            "difficulty":    q["difficulty"],
            "content_plain": strip_html(q.get("content") or ""),
            "starters":      starters,
            "test_cases":    test_cases,
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
    "auth_check":     cmd_auth_check,
    "auth_set":       cmd_auth_set,
    "problem_list":   cmd_problem_list,
    "problem_detail": cmd_problem_detail,
    "run_code":       cmd_run_code,
    "submit":         cmd_submit,
}

if __name__ == "__main__":
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
            print(json.dumps(result), flush=True)
        except Exception as e:
            print(json.dumps({"id": "", "ok": False, "error": str(e)}), flush=True)
