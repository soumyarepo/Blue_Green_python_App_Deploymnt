from flask import Flask
import os
app = Flask(__name__)
VERSION = os.getenv("APP_VERSION", "blue")
@app.route("/")
def home():
return f"Hello from {VERSION.upper()} version!"
if __name__ == "__main__":
app.run(host="0.0.0.0", port=5000)