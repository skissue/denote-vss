;;; org-roam-vss.el --- Vector similarity search for Org Roam -*- lexical-binding: t -*-

;; Author: skissue
;; Version: 0.1.0
;; Package-Requires: ((emacs "29") (org-roam "2.2.2") (llm "0.13.0"))
;; Homepage: https://github.com/skissue/org-roam-vss


;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; (WIP) Vector similarity search for Org Roam based on an embeddings database.

;;; Code:

(require 'org-roam)
(require 'llm)

(defvar org-roam-vss--db-connection nil
  "`org-roam-vss' SQLite database connection.")

(defcustom org-roam-vss-db-location (expand-file-name
                                     "org-roam-vss.db"
                                     (file-name-directory org-roam-db-location))
  "`org-roam-vss' SQLite database location."
  :type 'file)

(defcustom org-roam-vss-sqlite-vss-dir "./"
  "The directory where the 'sqlite-vss' libraries are stored."
  :type 'directory)

(defcustom org-roam-vss-llm nil
  "An instance of `llm' to use to generate embeddings."
  :type '(sexp :validate #'cl-struct-p))

(defcustom org-roam-vss-dimensions 768
  "The number of dimensions in the embedding vector generated by
`org-roam-vss-llm'. If this changes, the entire database MUST be
regenerated."
  :type 'number)

(defun org-roam-vss--query (select query &rest values)
  "Simple wrapper around `sqlite-execute' that uses
`org-roam-vss--db-connection' for the connection and ensures that
the connection has been initialized.

Executes QUERY with VALUES interpolated. Uses `sqlite-select' if
SELECT is non-nil."
  (org-roam-vss--maybe-connect)
  (if select
      (sqlite-select org-roam-vss--db-connection query values)
    (sqlite-execute org-roam-vss--db-connection query values)))

(defun org-roam-vss--maybe-connect ()
  "Call `org-roam-vss--db-connect' if
 `org-roam-vss--db-connection' hasn't been initialized yet."
  (unless org-roam-vss--db-connection
    (org-roam-vss--db-connect)))

(defun org-roam-vss--db-connect ()
  "Connect to SQLite database, set up 'sqlite-vss', and save connection in
`org-roam-vss--db-connection'."
  (setq org-roam-vss--db-connection (sqlite-open org-roam-vss-db-location))
  (sqlite-load-extension org-roam-vss--db-connection
                         (expand-file-name "vector0.so" org-roam-vss-sqlite-vss-dir))
  (sqlite-load-extension org-roam-vss--db-connection
                         (expand-file-name "vss0.so" org-roam-vss-sqlite-vss-dir))
  (org-roam-vss--create-table))

(defun org-roam-vss--create-table ()
  "Create 'roam_nodes' and 'vss_roam' tables if needed."
  (org-roam-vss--query
   ;; HACK For some reason, interpolating the dimensions doesn't work
   (format "CREATE VIRTUAL TABLE IF NOT EXISTS vss_roam USING vss0(embedding(%d))"
           org-roam-vss-dimensions)) 
  (org-roam-vss--query nil
   "CREATE TABLE IF NOT EXISTS roam_nodes
      (id INTEGER PRIMARY KEY AUTOINCREMENT,
       node_id TEXT UNIQUE)")
  (org-roam-vss--query nil
   "CREATE INDEX node_id_index ON roam_nodes(node_id)"))

(defun org-roam-vss--db-disconnect ()
  "Disconnect from SQLite database."
  (when org-roam-vss--db-connection
    (sqlite-close org-roam-vss--db-connection)
    (setq org-roam-vss--db-connection nil)))

(defun org-roam-vss--handle-returned-embedding (id embedding)
  "Handle a returned embedding, ready to be inserted into the SQLite database.

First, check if an embedding was previously saved for the node
 with ID; if not, insert a record to keep track of it. Then,
 update/insert the embedding into the embeddings table."
  (with-sqlite-transaction org-roam-vss--db-connection
    (let ((rowid (caar
                  (org-roam-vss--query :select
                   "SELECT id FROM roam_nodes WHERE node_id = ?"
                   id))))
      (unless rowid
        (setq rowid (caar
                     (org-roam-vss--query nil
                      "INSERT INTO roam_nodes(node_id) VALUES (?) RETURNING id"
                      id))))
      ;; sqlite-vss doesn't support UPDATE operations (yet)
      (org-roam-vss--query nil
       "DELETE FROM vss_roam WHERE rowid = ?"
       rowid)
      (org-roam-vss--query nil
       "INSERT INTO vss_roam(rowid, embedding) VALUES (?, ?)"
       rowid (json-encode embedding))))
  (message "Embeddings updated!"))

(defun org-roam-vss-update-embeddings (id)
  "Update or create the embeddings for the Org Roam node with ID.
 When called interactively, uses the node at point's ID.
 Processes embedding using
 `org-roam-vss--handle-returned-embedding'."
  (interactive (list (org-roam-node-id (org-roam-node-at-point))))
  (org-roam-vss--maybe-connect)
  (let ((node (org-roam-node-from-id id)))
    (unless node
      (user-error "No valid node found for given ID."))
    (org-roam-with-file (org-roam-node-file node) :kill
      ;; TODO Is exporting as text the best way to do this? For now, just a quick and easy solution.
      (let ((text (org-export-as 'ascii nil nil :body-only)))
        (llm-embedding-async
         org-roam-vss-llm text
         (lambda (embedding) (org-roam-vss--handle-returned-embedding id embedding))
         (lambda (sig err)
           (signal sig (list err))))))))

(defun org-roam-vss-query (query)
  "Search for all embeddings that are similar to QUERY."
  (interactive "sQuery: ")
  (llm-embedding-async
   org-roam-vss-llm query
   (lambda (embedding)
     (let* ((rows (org-roam-vss--query :select
                   "SELECT rowid, distance FROM vss_roam
                    WHERE vss_search(embedding, json(?))
                    LIMIT 20"
                   (json-encode embedding))))
       (message "%S" rows)))
   (lambda (sig err)
     (signal sig (list err)))))

(provide 'org-roam-vss)

;;; org-roam-vss.el ends here
