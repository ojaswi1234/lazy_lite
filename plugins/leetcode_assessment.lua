-- mod-version:3
-- LeetCode Assessment & Mock Test Platform for Lite XL
-- Replicates leetcode.com/assessment with Online Assessments, Phone Screens,
-- Onsite Loops, Live Timers, Question Switchers, and Comprehensive Scorecards.

local core = require "core"
local common = require "core.common"
local style = require "core.style"

local assessment = {}

assessment.PATTERNS = {
  { id = "sliding_window", idx = 1, name = "Sliding Window", tier = "Core", category = "Array / String", key_idea = "Optimize subarray/substring computations from O(n²) to O(n) using dynamic boundaries.", best_for = "Contiguous subarray/substring conditions with min/max length constraints.", canonical = {"longest-substring-without-repeating-characters", "minimum-size-subarray-sum", "sliding-window-maximum", "fruit-into-baskets", "max-consecutive-ones-iii", "permutation-in-string"} },
  { id = "two_pointers", idx = 2, name = "Two Pointers", tier = "Core", category = "Array / String", key_idea = "Process pairs, sorted arrays, or palindromes by advancing pointers from opposite or same ends in O(n).", best_for = "Sorted arrays, pair sums, partitioning, and palindrome validation.", canonical = {"two-sum-ii-input-array-is-sorted", "trapping-rain-water", "3sum", "container-with-most-water", "valid-palindrome"} },
  { id = "fast_slow_pointers", idx = 3, name = "Fast and Slow Pointers", tier = "Core", category = "Linked List / Cycles", key_idea = "Advance pointers at different speeds (1x, 2x) to detect cycles or find middle nodes in O(n) time and O(1) space.", best_for = "Cycle detection in linked lists/arrays, finding middle nodes, and happy numbers.", canonical = {"linked-list-cycle", "linked-list-cycle-ii", "middle-of-the-linked-list", "happy-number", "find-the-duplicate-number"} },
  { id = "merge_intervals", idx = 4, name = "Merge Intervals", tier = "Core", category = "Array / Intervals", key_idea = "Sort intervals by start time and merge or check overlaps based on boundary conditions in O(n log n).", best_for = "Overlapping intervals, scheduling, calendar conflicts, and range insertions.", canonical = {"merge-intervals", "insert-interval", "non-overlapping-intervals", "meeting-rooms-ii"} },
  { id = "cyclic_sort", idx = 5, name = "Cyclic Sort", tier = "Core", category = "Array", key_idea = "Place each number in range [1..n] at its correct index (val x -> index x-1) in O(n) time and O(1) extra space.", best_for = "Finding missing, duplicate, or corrupted numbers in a bounded [1..n] array.", canonical = {"missing-number", "find-all-duplicates-in-an-array", "first-missing-positive", "find-all-numbers-disappeared-in-an-array"} },
  { id = "subsets", idx = 6, name = "Subsets & Combinations", tier = "Core", category = "Recursion / Search", key_idea = "Generate powerset, combinations, or permutations systematically using recursion, BFS, or bitmasking.", best_for = "Exhaustive combinatorial generation, subset sums, and combinations.", canonical = {"subsets", "subsets-ii", "permutations", "combinations", "letter-combinations-of-a-phone-number"} },
  { id = "binary_search", idx = 7, name = "Binary Search", tier = "Core", category = "Search", key_idea = "Halve the search space repeatedly on sorted arrays or monotonic answer spaces in O(log n).", best_for = "Searching sorted collections, rotated arrays, peak finding, and 'binary search on answer'.", canonical = {"binary-search", "search-in-rotated-sorted-array", "find-minimum-in-rotated-sorted-array", "koko-eating-bananas", "split-array-largest-sum"} },
  { id = "backtracking", idx = 8, name = "Backtracking", tier = "Core", category = "Recursion / Search", key_idea = "Incrementally build candidate solutions and discard (backtrack) immediately when constraints fail.", best_for = "Constraint satisfaction (Sudoku, N-Queens), grid word search, and path enumeration.", canonical = {"n-queens", "word-search", "sudoku-solver", "palindrome-partitioning", "combination-sum"} },
  { id = "bfs", idx = 9, name = "Breadth-First Search (BFS)", tier = "Core", category = "Tree / Graph", key_idea = "Explore neighbors layer-by-layer using a queue to find shortest paths in unweighted graphs or level orders.", best_for = "Shortest path in unweighted grids/graphs, tree level-order traversal, and multi-source propagation.", canonical = {"binary-tree-level-order-traversal", "word-ladder", "rotting-oranges", "shortest-path-in-binary-matrix"} },
  { id = "dfs", idx = 10, name = "Depth-First Search (DFS)", tier = "Core", category = "Tree / Graph", key_idea = "Recursively explore each branch completely before backtracking to discover paths, connectivity, or subtrees.", best_for = "Connected components, tree traversals, path sums, and cycle detection.", canonical = {"number-of-islands", "all-paths-from-source-to-target", "max-area-of-island", "lowest-common-ancestor-of-a-binary-tree"} },
  { id = "topological_sort", idx = 11, name = "Topological Sort", tier = "Core", category = "Graph / DAG", key_idea = "Order vertices linearly in a DAG according to dependency prerequisites using Kahn's algorithm or DFS.", best_for = "Task scheduling, course prerequisites, build dependencies, and DAG cycle detection.", canonical = {"course-schedule", "course-schedule-ii", "alien-dictionary", "minimum-height-trees"} },
  { id = "union_find", idx = 12, name = "Union-Find (Disjoint Set)", tier = "Core", category = "Graph / Connectivity", key_idea = "Manage dynamic connected components with near-constant O(α(n)) amortized queries using path compression.", best_for = "Graph connectivity, redundant edges, minimum spanning trees, and dynamic clustering.", canonical = {"number-of-provinces", "redundant-connection", "accounts-merge", "number-of-operations-to-make-network-connected"} },
  { id = "greedy", idx = 13, name = "Greedy", tier = "Core", category = "Optimization", key_idea = "Make locally optimal choices at each step to reach a global optimum without backtracking.", best_for = "Interval scheduling, jump games, resource allocation, and task scheduling.", canonical = {"task-scheduler", "jump-game", "gas-station", "candy", "non-overlapping-intervals"} },
  { id = "dynamic_programming", idx = 14, name = "Dynamic Programming (DP)", tier = "Core", category = "Optimization / DP", key_idea = "Break problems into overlapping subproblems with optimal substructure; memoize solutions to achieve polynomial time.", best_for = "Longest sequences, knapsack, grid paths, coin change, and string edit distance.", canonical = {"longest-increasing-subsequence", "partition-equal-subset-sum", "coin-change", "edit-distance", "word-break"} },
  { id = "bit_manipulation", idx = 15, name = "Bit Manipulation", tier = "Core", category = "Bitwise Math", key_idea = "Leverage bitwise operations (XOR, AND, bitmask shifts) for fast math, parity tricks, and compact states.", best_for = "Single number queries, bit counting, power of two checks, and bitmask DP.", canonical = {"single-number", "single-number-ii", "counting-bits", "reverse-bits", "bitwise-and-of-numbers-range"} },
  { id = "matrix_traversal", idx = 16, name = "Matrix Traversal", tier = "Core", category = "Matrix / 2D Grid", key_idea = "Traverse 2D grids using directional offsets (dx, dy) combined with DFS, BFS, or DP transitions.", best_for = "Grid shortest paths, island counting, spiral iteration, and game simulation.", canonical = {"unique-paths", "rotting-oranges", "spiral-matrix", "set-matrix-zeroes", "game-of-life"} },
  { id = "heap_priority_queue", idx = 17, name = "Heap / Priority Queue", tier = "Core", category = "Data Structures", key_idea = "Maintain dynamically sorted top-K elements or dynamic order with O(log K) push/pop operations.", best_for = "Top-K frequent items, median in a stream, k-way merging, and task scheduling.", canonical = {"kth-largest-element-in-an-array", "merge-k-sorted-lists", "top-k-frequent-elements", "find-median-from-data-stream"} },
  { id = "divide_and_conquer", idx = 18, name = "Divide and Conquer", tier = "Core", category = "Algorithms", key_idea = "Divide problems into independent subproblems, solve recursively, and combine their results in O(n log n).", best_for = "Merge sort, median of sorted arrays, tree reconstruction, and polynomial multiplication.", canonical = {"median-of-two-sorted-arrays", "sort-an-array", "construct-binary-tree-from-preorder-and-inorder-traversal"} },
  { id = "prefix_sum", idx = 19, name = "Prefix Sum", tier = "Core", category = "Array", key_idea = "Precompute cumulative sums so arbitrary range sums can be queried in O(1) time.", best_for = "Subarray sum equals K, 2D range sum queries, difference arrays, and running products.", canonical = {"subarray-sum-equals-k", "range-sum-query-immutable", "product-of-array-except-self", "continuous-subarray-sum"} },
  { id = "sliding_window_maximum", idx = 20, name = "Sliding Window Maximum", tier = "Core", category = "Queue / Monotonic", key_idea = "Use a double-ended monotonic queue (deque) to maintain window extrema in amortized O(1) per step.", best_for = "Running maximum/minimum in fixed or sliding windows and jump game reachability.", canonical = {"sliding-window-maximum", "constrained-subsequence-sum", "jump-game-vi"} },
  { id = "kadanes_algorithm", idx = 21, name = "Kadane's Algorithm", tier = "Core", category = "Array / DP", key_idea = "Maintain a running current max sum and global max sum in a single pass O(n) time and O(1) space.", best_for = "Maximum subarray sum, circular max subarray, and max product subarray.", canonical = {"maximum-subarray", "maximum-sum-circular-subarray", "maximum-product-subarray"} },
  { id = "trie", idx = 22, name = "Trie (Prefix Tree)", tier = "Core", category = "Data Structures / String", key_idea = "Store strings in a prefix tree to allow O(L) prefix search, insertion, and dictionary autocomplete.", best_for = "Autocomplete, prefix lookups, 2D word search, and bitwise maximum XOR trees.", canonical = {"implement-trie-prefix-tree", "word-search-ii", "design-add-and-search-words-data-structure"} },
  { id = "segment_trees", idx = 23, name = "Segment Trees", tier = "Core / Advanced", category = "Data Structures / Range Queries", key_idea = "Tree structure enabling range queries and point/range updates in O(log n) time.", best_for = "Dynamic range sum/min/max queries with live updates and interval trees.", canonical = {"range-sum-query-mutable", "count-of-smaller-numbers-after-self", "falling-squares"} },
  { id = "graph_traversal", idx = 24, name = "Graph Traversal & Shortest Path", tier = "Core", category = "Graph", key_idea = "Traverse weighted or directed graphs using Dijkstra's, Bellman-Ford, or Floyd-Warshall to compute optimal routing.", best_for = "Shortest paths in weighted graphs, network delay, and minimum cost flow.", canonical = {"network-delay-time", "min-cost-to-connect-all-points", "cheapest-flights-within-k-stops"} },
  { id = "flood_fill", idx = 25, name = "Flood Fill", tier = "Core", category = "Matrix / DFS", key_idea = "Recursively or iteratively color/visit all connected and adjacent cells sharing the same property.", best_for = "Grid coloring, image fill, counting enclosed regions, and flood operations.", canonical = {"flood-fill", "number-of-enclaves", "island-perimeter", "surrounded-regions"} },
  { id = "monotonic_stack", idx = 26, name = "Monotonic Stack", tier = "Core", category = "Stack", key_idea = "Maintain an increasing/decreasing stack to find next greater/smaller elements in linear O(n) time.", best_for = "Next greater element, largest rectangle in histogram, daily temperatures, and stock span.", canonical = {"next-greater-element-i", "largest-rectangle-in-histogram", "daily-temperatures", "trapping-rain-water"} },
  { id = "string_matching", idx = 27, name = "String Matching (KMP, Rabin-Karp)", tier = "Core", category = "String Algorithms", key_idea = "Match patterns in text using preprocessing (LPS table in KMP, rolling hash in Rabin-Karp) in O(n+m).", best_for = "Substring search, periodic strings, and duplicate finding in large texts.", canonical = {"find-the-index-of-the-first-occurrence-in-a-string", "shortest-palindrome", "repeated-dna-sequences"} },
  { id = "fenwick_tree", idx = 28, name = "Binary Indexed Tree (Fenwick)", tier = "Core / Advanced", category = "Data Structures / Range Queries", key_idea = "Compact array-based tree structure to compute prefix sums and perform updates in O(log n) time.", best_for = "Dynamic frequency tables, prefix sums, and inversion counting.", canonical = {"range-sum-query-mutable", "count-of-smaller-numbers-after-self", "queue-reconstruction-by-height"} },
  { id = "reservoir_sampling", idx = 29, name = "Reservoir Sampling", tier = "Core", category = "Randomized", key_idea = "Randomly sample k items with uniform probability from an unknown or infinite data stream in a single pass.", best_for = "Streaming data selection, random node in linked list, and random index picking.", canonical = {"linked-list-random-node", "random-pick-index", "random-pick-with-weight"} },
  { id = "lru_cache", idx = 30, name = "LRU / LFU Cache Design", tier = "Core", category = "Design / Linked List", key_idea = "Combine hash maps with doubly linked lists to achieve O(1) key retrieval, update, and eviction.", best_for = "Caching systems, key-value stores, and frequency-based eviction.", canonical = {"lru-cache", "lfu-cache", "all-oone-data-structure"} },
  { id = "fibonacci_sequence", idx = 31, name = "Fibonacci & State Transitions", tier = "Core", category = "DP / Recurrence", key_idea = "Model linear recurrences f(n) = f(n-1) + f(n-2) iteratively in O(n) or with matrix exponentiation.", best_for = "Climbing stairs, house robber, tiling problems, and recurrence sequences.", canonical = {"climbing-stairs", "house-robber", "house-robber-ii", "fibonacci-number", "decode-ways"} },
  { id = "morris_traversal", idx = 32, name = "Morris Traversal", tier = "Advanced", category = "Tree", key_idea = "Use predecessor threading to traverse binary trees in O(n) time without recursion or stack (O(1) extra space).", best_for = "Space-constrained binary tree inorder and preorder traversals.", canonical = {"binary-tree-inorder-traversal", "recover-binary-search-tree"} },
  { id = "boyer_moore", idx = 33, name = "Boyer-Moore Majority Vote", tier = "Advanced", category = "Array / Counting", key_idea = "Find the majority element exceeding n/k occurrences in linear O(n) time and O(1) space using cancellation counters.", best_for = "Finding dominant elements with > n/2 or > n/3 frequency without hash maps.", canonical = {"majority-element", "majority-element-ii"} },
  { id = "rolling_hash", idx = 34, name = "Rolling Hash (Rabin-Karp)", tier = "Advanced", category = "String / Hash", key_idea = "Compute hashes of consecutive fixed-length substrings in O(1) per step via polynomial rolling hash.", best_for = "Duplicate DNA sequences, longest duplicate substring, and rabin-karp matching.", canonical = {"repeated-dna-sequences", "longest-duplicate-substring"} },
  { id = "manachers_algorithm", idx = 35, name = "Manacher's Algorithm", tier = "Advanced", category = "String / Palindrome", key_idea = "Find all sub-palindromes and the longest palindromic substring in strictly linear O(n) time.", best_for = "Longest palindromic substring and counting all palindromic substrings in linear time.", canonical = {"longest-palindromic-substring", "palindromic-substrings"} },
  { id = "catalan_numbers", idx = 36, name = "Catalan Numbers", tier = "Advanced", category = "Combinatorics / DP", key_idea = "Count valid nested configurations (balanced parentheses, BST shapes, triangulations) via Catalan recurrence.", best_for = "Counting unique binary search trees, valid parenthesis combinations, and dyck paths.", canonical = {"generate-parentheses", "unique-binary-search-trees"} },
  { id = "game_theory", idx = 37, name = "Game Theory (Minimax / Alpha-Beta)", tier = "Advanced", category = "Game / DP", key_idea = "Evaluate zero-sum turn-based games using minimax tree exploration with memoization and alpha-beta pruning.", best_for = "Stone games, Nim game, Can I Win, and optimal adversary strategies.", canonical = {"can-i-win", "stone-game", "nim-game", "cat-and-mouse"} },
  { id = "line_sweep", idx = 38, name = "Line Sweep", tier = "Advanced", category = "Geometry / Intervals", key_idea = "Sort discrete start/end events along a coordinate axis and process them sequentially to track active states.", best_for = "Skyline problem, meeting rooms count, area of overlapping rectangles, and geometric events.", canonical = {"meeting-rooms-ii", "the-skyline-problem", "perfect-rectangle"} },
  { id = "shortest_path", idx = 39, name = "Advanced Shortest Path Algorithms", tier = "Advanced", category = "Graph", key_idea = "Compute shortest distances in weighted/directed graphs using Dijkstra, Bellman-Ford, or SPFA.", best_for = "Cheapest flights within K stops, shortest paths with negative weights, and city connectivity.", canonical = {"cheapest-flights-within-k-stops", "path-with-minimum-effort"} },
  { id = "meet_in_middle", idx = 40, name = "Meet in the Middle", tier = "Advanced", category = "Search / Optimization", key_idea = "Split exponential search spaces (O(2^n)) into two halves of size n/2 and combine them via binary search / hashing.", best_for = "Subset sum with n<=40, 4Sum, and closest subsequence sum problems.", canonical = {"4sum", "closest-subsequence-sum", "split-array-with-same-average"} },
  { id = "critical_connections", idx = 41, name = "Critical Connections (Tarjan's Bridges)", tier = "Advanced", category = "Graph Algorithms", key_idea = "Discover bridges and articulation points in graphs using single-pass DFS low-link timestamps in O(V+E).", best_for = "Network reliability, critical edges, strongly connected components (SCC), and bridge finding.", canonical = {"critical-connections-in-a-network", "minimum-days-to-disconnect-island"} },
  { id = "z_algorithm", idx = 42, name = "Z-Algorithm", tier = "Advanced", category = "String Algorithms", key_idea = "Compute the Z-array (longest common prefix starting at each index) in linear O(n) time.", best_for = "Linear string matching, finding periodic prefixes, and palindrome prefix construction.", canonical = {"find-the-index-of-the-first-occurrence-in-a-string", "longest-happy-prefix"} },
  { id = "coordinate_compression", idx = 43, name = "Coordinate Compression", tier = "Advanced", category = "Geometry / Array", key_idea = "Map large coordinate ranges (e.g. 10^9) to a dense compact index space [0..k] to enable array/tree querying.", best_for = "Large 2D grid rectangles, discrete range sums, and sparse segment trees.", canonical = {"perfect-rectangle", "rectangle-area-ii"} },
  { id = "convex_hull", idx = 44, name = "Convex Hull", tier = "Advanced", category = "Computational Geometry", key_idea = "Compute the minimal convex polygon enclosing a set of 2D points using Graham Scan or Monotone Chain in O(n log n).", best_for = "Erect the fence, minimal enclosing geometry, and geometric bounds.", canonical = {"erect-the-fence", "maximum-darts-inside-circular-dartboard"} },
  { id = "sqrt_decomposition", idx = 45, name = "Sqrt Decomposition & Mo's Algorithm", tier = "Advanced", category = "Range Queries", key_idea = "Divide array into blocks of size √n to balance range query and update complexities to O(√n).", best_for = "Offline range queries (Mo's algorithm), block-based updates, and frequency queries.", canonical = {"range-sum-query-mutable", "count-of-range-sum"} },
  { id = "heavy_light_decomposition", idx = 46, name = "Heavy-Light Decomposition (HLD)", tier = "Advanced", category = "Tree Algorithms", key_idea = "Decompose tree paths into heavy chains to answer arbitrary node-to-node path queries in O(log² n).", best_for = "Tree path sum queries, dynamic tree node updates, and competitive tree queries.", canonical = {"maximum-score-after-applying-operations-on-a-tree"} },
  { id = "network_flow", idx = 47, name = "Network Flow (Max Flow / Min Cut)", tier = "Advanced", category = "Graph / Optimization", key_idea = "Model assignment and capacity constraints as flow networks and solve using Dinic's or Ford-Fulkerson.", best_for = "Maximum bipartite matching, min-cut partitioning, and resource assignment.", canonical = {"maximum-students-taking-exam", "maximum-bipartite-matching"} },
  { id = "persistent_data_structures", idx = 48, name = "Persistent Data Structures", tier = "Advanced", category = "Data Structures", key_idea = "Maintain historical versions of trees or arrays by sharing unchanged nodes on each update in O(log n).", best_for = "Version control systems, historical range queries, and functional trees.", canonical = {"version-control-systems", "functional-programming-structures"} },
  { id = "suffix_array", idx = 49, name = "Suffix Array / Suffix Tree", tier = "Advanced", category = "String Algorithms", key_idea = "Sort all suffixes of a string to perform fast substring searching, duplicate detection, and LCP queries.", best_for = "Longest duplicate substring, lexicographical suffix queries, and string processing.", canonical = {"longest-duplicate-substring", "last-substring-in-lexicographical-order"} },
  { id = "aho_corasick", idx = 50, name = "Aho-Corasick Algorithm", tier = "Advanced", category = "String Matching", key_idea = "Build a Trie with failure transitions to search for multiple dictionary patterns simultaneously in linear time.", best_for = "Stream of characters, multi-pattern search, and keyword dictionary filtering.", canonical = {"stream-of-characters", "multi-search-lcci"} }
}

assessment.TRACKS = {
  {
    id = "oa",
    title = "Online Assessment",
    badge = "OA SCREEN",
    subtitle = "Automated Online Screening (HackerRank / Codility)",
    icon = "[OA]",
    duration_mins = 60,
    diffs = { "EASY", "MEDIUM" },
    question_count = 2,
    desc = "2 Problems | 60 Minutes | 1 Easy + 1 Medium. Simulates modern automated screening rounds."
  },
  {
    id = "phone",
    title = "Phone Screen Interview",
    badge = "PHONE SCREEN",
    subtitle = "Live Technical Screening with Software Engineer",
    icon = "[PHONE]",
    duration_mins = 45,
    diffs = { "EASY", "MEDIUM" },
    question_count = 2,
    desc = "2 Problems | 45 Minutes | Speed, clarity, and bug-free implementation under constraint."
  },
  {
    id = "onsite",
    title = "Onsite Interview Loop",
    badge = "ONSITE LOOP",
    subtitle = "Comprehensive Technical Onsite Day",
    icon = "[ONSITE]",
    duration_mins = 120,
    diffs = { "EASY", "MEDIUM", "HARD" },
    question_count = 3,
    desc = "3 Problems | 120 Minutes | Full spectrum: 1 Easy, 1 Medium, and 1 Hard problem."
  },
  {
    id = "company",
    title = "Google Assessment",
    badge = "COMPANY OA",
    subtitle = "Target Company Specific Interview Patterns",
    icon = "[TARGET]",
    company = "google",
    duration_mins = 60,
    diffs = { "MEDIUM", "MEDIUM" },
    question_count = 2,
    desc = "2 Problems | 60 Minutes | Real interview questions frequently asked by Google."
  },
  {
    id = "pattern",
    title = "Pattern: Sliding Window",
    badge = "PATTERN DRILL",
    subtitle = "50 Essential Algorithmic Patterns Mastery",
    icon = "[PATTERN]",
    pattern_id = "sliding_window",
    pattern_idx = 1,
    pattern_name = "Sliding Window",
    duration_mins = 60,
    diffs = { "EASY", "MEDIUM" },
    question_count = 2,
    desc = "2 Problems | 60 Minutes | Master canonical problems testing Sliding Window."
  }
}

assessment.selected_company = "google"
assessment.selected_company_display = "Google"
assessment.selected_company_topic = nil
assessment.selected_pattern = "sliding_window"
assessment.selected_pattern_idx = 1
assessment.selected_pattern_name = "Sliding Window"
assessment.selected_topic = nil
assessment.selected_topic_name = nil
assessment.selected_mode = "pattern" -- "pattern" or "topic"

function assessment.get_pattern(id_or_idx)
  if type(id_or_idx) == "number" then
    for _, p in ipairs(assessment.PATTERNS) do
      if p.idx == id_or_idx then return p end
    end
  elseif type(id_or_idx) == "string" then
    local s = id_or_idx:lower()
    for _, p in ipairs(assessment.PATTERNS) do
      if p.id:lower() == s or p.name:lower() == s then return p end
    end
  end
  return assessment.PATTERNS[1]
end

function assessment.set_target_pattern(pat_id_or_idx)
  local p = assessment.get_pattern(pat_id_or_idx)
  if not p then return end
  assessment.selected_pattern = p.id
  assessment.selected_pattern_idx = p.idx
  assessment.selected_pattern_name = p.name
  assessment.selected_mode = "pattern"
  assessment.selected_topic = nil
  assessment.selected_topic_name = nil

  if assessment.TRACKS[5] then
    assessment.TRACKS[5].mode = "pattern"
    assessment.TRACKS[5].pattern_id = p.id
    assessment.TRACKS[5].pattern_idx = p.idx
    assessment.TRACKS[5].pattern_name = p.name
    assessment.TRACKS[5].topic = nil
    assessment.TRACKS[5].title = "Pattern #" .. tostring(p.idx) .. ": " .. p.name
    assessment.TRACKS[5].badge = "[PATTERN #" .. tostring(p.idx) .. "]"
    assessment.TRACKS[5].subtitle = p.category .. " (" .. p.tier .. ")"
    assessment.TRACKS[5].desc = "2 Problems | 60 Mins | Master canonical problems testing " .. p.name .. "."
  end
end

function assessment.set_target_topic(topic_tag, topic_name)
  if not topic_tag or topic_tag == "" then return end
  local tag_clean = topic_tag:lower():gsub("^#", "")
  local tag_disp = topic_name or tag_clean:gsub("^%l", string.upper):gsub("%-(%l)", function(s) return " " .. s:upper() end)

  assessment.selected_topic = tag_clean
  assessment.selected_topic_name = tag_disp
  assessment.selected_mode = "topic"

  if assessment.TRACKS[5] then
    assessment.TRACKS[5].mode = "topic"
    assessment.TRACKS[5].topic = tag_clean
    assessment.TRACKS[5].pattern_id = nil
    assessment.TRACKS[5].title = "Topic: #" .. tag_clean
    assessment.TRACKS[5].badge = "[#" .. tag_clean:upper() .. "]"
    assessment.TRACKS[5].subtitle = tag_disp .. " (Native LeetCode Topic)"
    assessment.TRACKS[5].desc = "2 Problems | 60 Mins | Targeted problems from LeetCode's #" .. tag_clean .. " tag database."
  end
end

assessment.selected_company_mode = "ml_auto" -- "ml_auto" (ML linear regression + clustering) or "topic_filter"

function assessment.set_target_company(company_name, topic_filter, force_mode)
  local c_clean = (company_name or "google"):lower():gsub("%s+", "-")
  local c_display = c_clean:gsub("^%l", string.upper):gsub("%-(%l)", function(s) return " " .. s:upper() end)
  local t_clean = (topic_filter and topic_filter ~= "" and topic_filter ~= "ALL") and topic_filter:lower():gsub("^#", "") or nil
  
  assessment.selected_company = c_clean
  assessment.selected_company_display = c_display
  assessment.selected_company_topic = t_clean

  if force_mode then
    assessment.selected_company_mode = force_mode
  elseif t_clean then
    assessment.selected_company_mode = "topic_filter"
  else
    assessment.selected_company_mode = "ml_auto"
  end
  
  if assessment.TRACKS[4] then
    assessment.TRACKS[4].company = c_clean
    assessment.TRACKS[4].topic = t_clean
    assessment.TRACKS[4].mode = assessment.selected_company_mode
    if assessment.selected_company_mode == "topic_filter" and t_clean then
      assessment.TRACKS[4].title = c_display .. " OA [#" .. t_clean .. "]"
      assessment.TRACKS[4].badge = "[" .. c_clean:upper() .. " #" .. t_clean:upper() .. "]"
      assessment.TRACKS[4].subtitle = c_display .. " Filtered by #" .. t_clean
      assessment.TRACKS[4].desc = "2 Problems | 60 Mins | Target " .. c_display .. " questions focusing on #" .. t_clean .. "."
    else
      assessment.TRACKS[4].title = c_display .. " Assessment (ML Predicted)"
      assessment.TRACKS[4].badge = "[" .. c_clean:upper() .. " | ML OA]"
      assessment.TRACKS[4].subtitle = c_display .. " ML Archetype & Trend Prediction"
      assessment.TRACKS[4].desc = "2 Problems | 60 Mins | Auto-predicted by ML Linear Regression & K-Means clustering across " .. c_display .. " hiring trends."
    end
  end
end

function assessment.set_target_company_topic(topic_filter)
  if not topic_filter or topic_filter == "" or topic_filter == "ALL" then
    assessment.set_target_company(assessment.selected_company, nil, "ml_auto")
  else
    assessment.set_target_company(assessment.selected_company, topic_filter, "topic_filter")
  end
end


assessment.session = nil
assessment.history = {}

function assessment.is_active()
  return assessment.session ~= nil and not assessment.session.completed
end

function assessment.get_session()
  return assessment.session
end

function assessment.start_session(track_info, questions_data, lang, blind_mode, curveballs)
  local now = os.time()
  local q_list = {}

  for i, q in ipairs(questions_data) do
    table.insert(q_list, {
      idx = i,
      slug = q.slug or q.titleSlug,
      title = q.title or q.slug,
      difficulty = q.difficulty or "Medium",
      pattern_name = q.pattern_name,
      pattern_id = q.pattern_id,
      pattern_idx = q.pattern_idx,
      topic = q.topic,
      topics = q.topics,
      cluster_name = q.cluster_name,
      selection_reason = q.selection_reason,
      trend_score = q.trend_score,
      problem_data = q,
      status = "unattempted", -- "unattempted", "in_progress", "accepted", "wrong", "tle", "error"
      submissions_count = 0,
      runs_count = 0,
      test_cases_passed = 0,
      total_test_cases = 0,
      start_time = now,
      time_spent = 0,
      est_tc = "O(?)",
      est_sc = "O(?)",
      result = nil,
      code = nil,
    })
  end

  assessment.session = {
    track = track_info,
    title = track_info.title,
    duration_mins = track_info.duration_mins,
    start_time = now,
    end_time = now + (track_info.duration_mins * 60),
    blind_mode = blind_mode or false,
    curveballs = curveballs ~= false,
    lang = lang or "python3",
    questions = q_list,
    current_q_idx = 1,
    curveball_triggered = false,
    active_curveball = nil,
    completed = false,
    scorecard = nil,
  }

  if q_list[1] then
    q_list[1].last_active_time = now
    q_list[1].status = "in_progress"
  end

  return assessment.session
end

function assessment.switch_question(idx)
  if not assessment.session then return false end
  local questions = assessment.session.questions
  if idx >= 1 and idx <= #questions then
    -- Record time on current question
    local cur = questions[assessment.session.current_q_idx]
    if cur and cur.last_active_time then
      cur.time_spent = cur.time_spent + (os.time() - cur.last_active_time)
    end

    assessment.session.current_q_idx = idx
    local next_q = questions[idx]
    next_q.last_active_time = os.time()
    if next_q.status == "unattempted" then
      next_q.status = "in_progress"
    end
    return true
  end
  return false
end

function assessment.get_current_question()
  if not assessment.session then return nil end
  return assessment.session.questions[assessment.session.current_q_idx]
end

function assessment.on_run_result(slug, result)
  if not assessment.session then return end
  for _, q in ipairs(assessment.session.questions) do
    if q.slug == slug or (q.problem_data and q.problem_data.slug == slug) then
      q.runs_count = q.runs_count + 1
      q.est_tc = result.est_tc or q.est_tc
      q.est_sc = result.est_sc or q.est_sc
      if q.status == "unattempted" then q.status = "in_progress" end
      break
    end
  end
end

function assessment.on_submit_result(slug, result)
  if not assessment.session then return end
  for _, q in ipairs(assessment.session.questions) do
    if q.slug == slug or (q.problem_data and q.problem_data.slug == slug) then
      q.submissions_count = q.submissions_count + 1
      q.result = result
      q.est_tc = result.est_tc or q.est_tc
      q.est_sc = result.est_sc or q.est_sc
      
      if result.total_correct and result.total_testcases then
        q.test_cases_passed = result.total_correct
        q.total_test_cases = result.total_testcases
      end

      if result.ok or (result.status and (result.status:match("Accepted") or result.status:match("AC"))) then
        q.status = "accepted"
      elseif result.status and result.status:match("Limit Exceeded") then
        q.status = "tle"
      elseif result.compile_error or (result.status and result.status:match("Error")) then
        q.status = "error"
      else
        q.status = "wrong"
      end
      break
    end
  end
end

function assessment.finish_session()
  if not assessment.session or assessment.session.completed then return end
  local sess = assessment.session
  sess.completed = true
  sess.finish_time = os.time()
  sess.total_time_used = math.min(sess.duration_mins * 60, sess.finish_time - sess.start_time)

  -- Finalize time on active question
  local cur = sess.questions[sess.current_q_idx]
  if cur and cur.last_active_time then
    cur.time_spent = cur.time_spent + (sess.finish_time - cur.last_active_time)
    cur.last_active_time = nil
  end

  -- Calculate score and scorecard
  local total_q = #sess.questions
  local accepted_count = 0
  local total_submissions = 0
  local total_wrong_subs = 0
  local q_scores = {}

  for _, q in ipairs(sess.questions) do
    total_submissions = total_submissions + q.submissions_count
    if q.status == "accepted" then
      accepted_count = accepted_count + 1
      total_wrong_subs = total_wrong_subs + math.max(0, q.submissions_count - 1)
      table.insert(q_scores, 100)
    elseif q.total_test_cases > 0 and q.test_cases_passed > 0 then
      total_wrong_subs = total_wrong_subs + q.submissions_count
      local partial = math.floor((q.test_cases_passed / q.total_test_cases) * 70)
      table.insert(q_scores, partial)
    else
      total_wrong_subs = total_wrong_subs + q.submissions_count
      table.insert(q_scores, 0)
    end
  end

  -- Base Accuracy (Max 70%)
  local base_accuracy = (accepted_count / math.max(1, total_q)) * 70
  if accepted_count < total_q and #q_scores > 0 then
    local sum_partials = 0
    for _, s in ipairs(q_scores) do sum_partials = sum_partials + s end
    base_accuracy = (sum_partials / (#q_scores * 100)) * 70
  end

  -- Time Bonus (Max 20%)
  local time_ratio = sess.total_time_used / (sess.duration_mins * 60)
  local time_bonus = 0
  if accepted_count == total_q then
    if time_ratio <= 0.40 then
      time_bonus = 20
    elseif time_ratio <= 0.70 then
      time_bonus = 15
    elseif time_ratio <= 0.90 then
      time_bonus = 10
    else
      time_bonus = 5
    end
  elseif accepted_count > 0 then
    time_bonus = math.max(0, math.floor((1 - time_ratio) * 10))
  end

  -- Submission Penalty (Deduct 3 pts per failed submission, max 10 pts deduction)
  local penalty = math.min(10, total_wrong_subs * 3)

  -- Final Normalized Score (0 - 100)
  local final_score = math.max(0, math.min(100, math.floor(base_accuracy + time_bonus - penalty)))

  -- Hiring Verdict Calculation
  local verdict, verdict_color, verdict_desc
  if final_score >= 90 then
    verdict = "Strong Hire"
    verdict_color = { 44, 187, 93 } -- Green
    verdict_desc = "Outstanding performance! All test cases passed with optimal complexity and fast completion time."
  elseif final_score >= 75 then
    verdict = "Hire"
    verdict_color = { 104, 193, 113 } -- Soft Green
    verdict_desc = "Solid engineering demonstration. Clean problem-solving with high accuracy."
  elseif final_score >= 60 then
    verdict = "Lean Hire / Borderline"
    verdict_color = { 255, 192, 30 } -- Amber
    verdict_desc = "Good effort with partial test passes or minor penalties. Recommend further practice under time limits."
  else
    verdict = "No Hire / Needs Practice"
    verdict_color = { 255, 55, 95 } -- Red
    verdict_desc = "Multiple unsolved edge cases or time elapsed. Revisit algorithmic patterns and time management."
  end

  sess.scorecard = {
    score = final_score,
    verdict = verdict,
    verdict_color = verdict_color,
    verdict_desc = verdict_desc,
    accepted_count = accepted_count,
    total_questions = total_q,
    total_time_used = sess.total_time_used,
    allocated_time = sess.duration_mins * 60,
    submissions_count = total_submissions,
    penalties = penalty,
    time_bonus = time_bonus,
    base_accuracy = math.floor(base_accuracy),
    date_str = os.date("%Y-%m-%d %H:%M"),
  }

  table.insert(assessment.history, 1, sess.scorecard)
  return sess.scorecard
end

return assessment
