import sys
import json
from pymongo import MongoClient
from bson import json_util

def main():
    client = None
    uri = None
    
    # Ready signal removed to prevent race condition with first command response
    
    for line in sys.stdin:
        try:
            req = json.loads(line.strip())
            action = req.get("action")
            req_uri = req.get("uri")
            
            # Connect or reconnect if URI changed
            if action == "connect" or (req_uri and req_uri != uri):
                uri = req_uri
                if client:
                    client.close()
                client = MongoClient(uri, serverSelectionTimeoutMS=5000)
                # Test connection
                client.admin.command('ping')
                
                if action == "connect":
                    print(json.dumps({"success": True, "action": "connect"}))
                    sys.stdout.flush()
                    continue
            
            if not client:
                print(json.dumps({"success": False, "error": "Not connected"}))
                sys.stdout.flush()
                continue
                
            if action == "list_databases":
                dbs = client.list_database_names()
                print(json.dumps({"success": True, "action": action, "databases": dbs}))
                
            elif action == "list_collections":
                db_name = req.get("db")
                db = client[db_name]
                collections = db.list_collection_names()
                print(json.dumps({"success": True, "action": action, "collections": collections}))
                
            elif action == "find":
                db_name = req.get("db")
                col_name = req.get("collection")
                query = req.get("query", {})
                limit = req.get("limit", 50)
                
                db = client[db_name]
                col = db[col_name]
                
                cursor = col.find(query).limit(limit)
                docs = list(cursor)
                
                # Use bson.json_util to serialize ObjectId and Dates properly
                docs_json = json_util.dumps(docs)
                print(json.dumps({"success": True, "action": action, "documents": json.loads(docs_json)}))
                
            else:
                print(json.dumps({"success": False, "error": f"Unknown action: {action}"}))
                
        except Exception as e:
            print(json.dumps({"success": False, "error": str(e)}))
            
        sys.stdout.flush()

if __name__ == "__main__":
    main()
