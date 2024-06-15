;;; denote-vss.el --- Vector similarity search for Denote -*- lexical-binding: t -*-

;; Author: Ad <me@skissue.xyz>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

;; (WIP) Vector similarity search for Denote using sqlite-vss.

;;; Code:

(require 'denote)
(require 'llm)
(require 'sqlite)

(defcustom denote-vss-db-location (expand-file-name "denote-vss.db"
                                                    denote-directory)
  "`denote-vss' SQLite database location."
  :type 'file)

(defcustom denote-vss-sqlite-vss-dir nil
  "The directory where the `sqlite-vss' libraries are stored."
  :type 'directory)

(defcustom denote-vss-llm nil
  "An instance of `llm' to use to generate embeddings.
Changing this requires regenerating the entire database!"
  :type '(sexp :validate #'cl-struct-p))

(defcustom denote-vss-dimensions 768
  "Number of dimensions in the embedding vector generated by `denote-vss-llm'.
If this changes, the entire database MUST be regenerated."
  :type 'number)

(defcustom denote-vss-node-content-function #'denote-vss-extract-whole-document
  "Function to extract documents from a node.
Should take a single argument NODE, and return a list of cons cells
where the car is the point where the document should start and the cdr
is where the document should end. Will be called with NODE's file as the
active buffer.

Defaults to `denote-vss-node-whole-document', which returns the
entire node's content as one document."
  :type 'function)

(defvar denote-vss--db-connection nil
  "`denote-vss' SQLite database connection.")

(defun denote-vss--query (select query &rest values)
  "Execute QUERY with VALUES interpolated.
Simple wrapper around `sqlite-execute' that uses
`denote-vss--db-connection' for the connection and ensures that the
connection has been initialized.

Uses `sqlite-select' if SELECT is non-nil."
  (denote-vss--maybe-connect)
  (if select
      (sqlite-select denote-vss--db-connection query values)
    (sqlite-execute denote-vss--db-connection query values)))

(defun denote-vss--maybe-connect ()
  "Initialize the database connection if needed.
Calls `denote-vss--db-connect' if `denote-vss--db-connection' is nil."
  (unless denote-vss--db-connection
    (denote-vss--db-connect)))

(defun denote-vss--db-connect ()
  "Initialize SQLite database connection and setup.
Connect to SQLite database, set up 'sqlite-vss', create tables if
necessary, and save connection in `denote-vss--db-connection'."
  (setq denote-vss--db-connection (sqlite-open denote-vss-db-location))
  (dolist (plugin '("vector0.so" "vss0.so"))
    (sqlite-load-extension denote-vss--db-connection
                           (expand-file-name plugin denote-vss-sqlite-vss-dir)))
  (denote-vss--create-table))

(defun denote-vss--create-table ()
  "Create `documents' and `vss_denote' tables if needed."
  (denote-vss--query
   ;; HACK For some reason, interpolating the dimensions doesn't work
   nil (format "CREATE VIRTUAL TABLE IF NOT EXISTS vss_denote USING vss0(embedding(%d))"
               denote-vss-dimensions)) 
  (denote-vss--query
   nil "CREATE TABLE IF NOT EXISTS documents
        (id INTEGER PRIMARY KEY AUTOINCREMENT,
         denote_id TEXT,
         content TEXT,
         point INT)")
  (denote-vss--query
   nil "CREATE INDEX IF NOT EXISTS denote_id_index ON documents(denote_id)"))

(defun denote-vss--db-disconnect ()
  "Close SQLite connection."
  (when denote-vss--db-connection
    (sqlite-close denote-vss--db-connection)
    (setq denote-vss--db-connection nil)))

(defmacro denote-vss--with-embedding (text &rest body)
  "Wrapper around `llm-embedding-async' that executes BODY with the
embedding of TEXT bound to `embedding'."
  `(llm-embedding-async
    denote-vss-llm ,text
    (lambda (embedding) ,@body)
    (lambda (sig err)
      (signal sig (list err)))))
(put 'denote-vss--with-embedding 'lisp-indent-function 'defun)

(defun denote-vss-extract-whole-document (file)
  "Return the entire body of FILE as a single document.
Simple, but may not work well if you have nodes with large amounts of
content."
  (list (with-temp-buffer
          (insert-file-contents file)
          (cons (point-min) (buffer-string)))))

(defun denote-vss-node-paragraph-documents (file)
  "Return every paragraph from FILE as an individual document.
Paragraphs are determined by two consecutive newlines."
  (with-temp-buffer
    (insert-file-contents file)
    (cl-loop while (< (point) (point-max))
             for start = (point)
             and end = (progn
                         (re-search-forward "\n\n" nil :to-end)
                         (point))
             collect (cons start end))))

(defun denote-vss--clear-embeddings (id)
  "Clear all embeddings for the note with ID from the database."
  (with-sqlite-transaction denote-vss--db-connection
    (let ((rows (denote-vss--query
                 :select "SELECT id FROM documents WHERE denote_id = ?"
                 id)))
      (dolist (row rows)
        (denote-vss--query
         nil "DELETE FROM vss_denote WHERE rowid = ?"
         (car row)))
      (denote-vss--query
       nil "DELETE FROM documents WHERE denote_id = ?"
       id))))

(defun denote-vss--handle-returned-embedding (id document embedding)
  "Insert a returned EMBEDDING for DOCUMENT into the database with ID."
  (with-sqlite-transaction denote-vss--db-connection
    (let ((rowid (caar
                  (denote-vss--query
                   nil "INSERT INTO documents(denote_id, point, content)
                        VALUES (?, ?, ?) RETURNING id"
                   id (car document) (cdr document)))))
      (denote-vss--query
       nil "INSERT INTO vss_denote(rowid, embedding) VALUES (?, ?)"
       rowid (json-encode embedding))))
  (message "Embeddings updated!"))

(defun denote-vss--get-xref-item (id point content)
  "Return an `xref-match-item' for note with ID at POINT with CONTENT."
  (let* ((file (denote-get-path-by-id id))
         ;; It may seem wasteful to open a buffer for every searched file, but
         ;; xref actually does this in the background with `xref-file-location'
         ;; anyway; the reason we don't use it is because it wants a line and
         ;; column number, but we're storing the point.
         (buf (find-file-noselect file)))
    (xref-make-match
     content
     (xref-make-buffer-location buf point)
     (length content))))

;;;###autoload
(defun denote-vss-update-embeddings (file)
  "Update or create the embeddings for the Denote note FILE.
When called interactively, uses the active buffer's file if it is a
Denote note."
  (interactive (list buffer-file-name))
  (unless (and file (denote-file-is-note-p file))
    (user-error "No valid note found!"))
  (denote-vss--maybe-connect)
  (let ((id (denote-retrieve-filename-identifier file)))
    (denote-vss--clear-embeddings id)
    (dolist (document (funcall denote-vss-node-content-function file))
      (denote-vss--with-embedding (cdr document)
        (denote-vss--handle-returned-embedding
         id document embedding)))))

;;;###autoload
(defun denote-vss-update-all ()
  "Update embeddings for all nodes."
  (interactive)
  (dolist (file (denote-directory-files))
    (denote-vss-update-embeddings file)))

;;;###autoload
(defun denote-vss-clear-db (arg)
  "Clear all entries from embeddings database.
With prefix argument ARG, don't request user confirmation."
  (interactive "P")
  (when (or arg
            (yes-or-no-p "Really clear database?"))
    (denote-vss--query
     nil "DROP TABLE documents")
    (denote-vss--query
     nil "DROP TABLE vss_denote")
    (denote-vss--create-table)))

;;;###autoload
(defun denote-vss-search (query)
  "Search for all embeddings that are similar to QUERY."
  (interactive "sQuery: ")
  (denote-vss--with-embedding query
    (let* ((rows (denote-vss--query
                  ;; HACK When doing a JOIN, sqlite-vss complains about the lack
                  ;; of a LIMIT clause even when it is present, so use the old
                  ;; way of doing it instead.
                  :select "SELECT denote_id, content, point, distance FROM vss_denote
                           JOIN documents ON vss_denote.rowid = documents.id
                           WHERE vss_search(embedding, vss_search_params(json(?), 20))"
                  (json-encode embedding))))
      (xref-show-xrefs
       (mapcar (lambda (row)
                 (cl-destructuring-bind (id content point dist) row
                   (denote-vss--get-xref-item id point content)))
               rows)
       nil))))

(provide 'denote-vss)

;;; denote-vss.el ends here
