;; urbit-graph.el --- Urbit graph library -*- lexical-binding: t -*-

;; Author: Noah Evans <noah@nevans.me>

;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.


;;; Commentary:

;;; Code for interacting with urbit graphs.

;;; Code:

(require 'request)
(require 'aio)
(require 'urbit-http)



;;
;; Variables
;;
(defvar urbit-graph-update-subscription nil
  "Urbit-http graph-store /update subscription")

;; TODO: Cache this on disk
(defvar urbit-graph-graphs '()
  "Alist of resource symbolds to graphs.")

;; TODO: How do users of the library access and watch graphs?
(defvar urbit-graph-hooks '()
  "Alist of resource symbolds to hook objects for watching graphs.")

;;
;; Macros
;;
(pcase-defmacro urbit-graph-match-key (key)
  "Matches if EXPVAL is an alist with KEY, and let binds val to the value of that key."
  `(and (pred (assoc ,key))
        (app (alist-get ,key) val)))

(defmacro urbit-graph-let-resource (&rest body)
  "Bind ship to ensigged ship, and create a resource."
  `(let* ((ship (urbit-ensig ship))
          (resource (urbit-graph-make-resource ship name)))
     ,@body))

;;
;; Functinos
;;
(aio-defun urbit-graph-init ()
  ;; TODO: Probably should cache graphs to disk and load them
  (setq urbit-graph-graphs nil) 
  (setq urbit-graph-hooks nil)
  (setq urbit-graph-update-subscription
        (aio-await
         (urbit-http-subscribe "graph-store"
                               "/updates"
                               #'urbit-graph-update-handler))))



(defun urbit-graph-index-symbol-to-list (symbol)
  (mapcar #'string-to-number
          (split-string (symbol-name symbol) "/" t)))

(defun urbit-graph-resource-to-symbol (resource)
  "Turn a RESOURCE object into a symbol."
  (intern (concat (alist-get 'ship resource)
                  "/"
                  (alist-get 'name resource))))

;;
;; Event handling
;;

;; TODO: should probably create the graph if it doesn't exist
(defun urbit-graph-add-nodes-handler (data)
  "Handle add-nodes graph-update action."
  (let-alist data
    (let* ((resource-symbol (urbit-graph-resource-to-symbol .resource))
           (graph (alist-get resource-symbol urbit-graph-graphs))
           (hooks (alist-get resource-symbol urbit-graph-hooks)))
      (defun add-node (graph index post)
        (if (= (length index) 1) (nconc graph (list (cons (car index) post)))
          (let ((parent (alist-get (car index) graph)))
            (if (not parent) (urbit-log "Parent not found for: %s" index)
              (add-node (assoc 'children parent)
                        (cdr index)
                        post)))))
      (dolist (node .nodes)
        (let ((index (urbit-graph-index-symbol-to-list (car node)))
              (post (cdr node)))
          (add-node graph index post))))))

(defun urbit-graph-add-graph-handler (data)
  (let-alist data
    (let ((resource-symbol (urbit-graph-resource-to-symbol .resource)))
      (when (assoc resource-symbol urbit-graph-graphs)
        (urbit-log "Add Graph: Graph %s already added" resource-symbol))
      ;; Convert all of the indexes to numbers
      (defun clean-graph (graph)
        (dolist (node graph)
          (setf (car node)
                (string-to-number (substring (symbol-name (car node)))))
          (let ((children (alist-get 'children (cdr node))))
            (setf children (clean-graph children)))))
      (clean-graph .graph)
      (add-to-list 'urbit-graph-graphs
                   (cons resource-symbol .graph)))))

(defun urbit-graph-update-handler (event)
  "Handle graph-update EVENT."
  (let ((graph-update (alist-get 'graph-update event)))
    (if (not graph-update) (urbit-log "Unknown graph event: %s" event)
      (pcase graph-update
        ((urbit-graph-match-key 'add-nodes) (urbit-graph-add-nodes-handler val))
        ((urbit-graph-match-key 'add-graph) (urbit-graph-add-graph-handler val))
        ((urbit-graph-match-key 'remove-node) (urbit-log "Remove node not implemented"))
        ((urbit-graph-match-key 'remove-graph) (urbit-log "Remove graph not implemented"))
        (- (urbit-log "Unkown graph-update: %s" graph-update))))))


;;
;; Helpers
;; 

;; TODO: bad function figure out actual subscription
(aio-defun urbit-graph-subscribe (ship name callback)
  "Subscribe to a graph at SHIP and NAME, calling CALLBACK with a list of new nodes on each update."
  (add-to-list 'urbit-graph-subscriptions
               (cons
                (urbit-graph-resource-to-symbol `((ship . ,ship)
                                                  (name . ,name)))
                callback)))



;;
;; Constructors
;;
(defun urbit-graph-make-post (contents &optional parent-index child-index)
  "Create a new post with CONTENTS.
CONTENTS is a vector or list of content objects."
  (let ((contents (if (vectorp contents)
                      contents
                    (vconcat contents))))
    `((index . ,(concat "/" (urbit-da-time)))
      (author . ,(concat "~" urbit-ship))
      (time-sent . ,(urbit-milli-time))
      (signatures . [])
      (contents . ,contents)
      (hash . nil))))

(defun urbit-graph-make-node (post &optional children)
  "Make an urbit graph node."
  `(,(alist-get 'index post)
    (post . ,post)
    (children . ,children)))

(defun urbit-graph-make-resource (ship name)
  `(resource (ship . ,ship)
             (name . ,name)))
;;
;; Actions
;;
(defun urbit-graph-store-action (action &optional ok-callback err-callback)
  (urbit-http-poke "graph-store"
                   "graph-update"
                   action
                   ok-callback
                   err-callback))

(defun urbit-graph-view-action (thread-name action)
  (urbit-http-spider "graph-view-action"
                     "json"
                     thread-name
                     action))

(defun urbit-graph-hook-action (action &optional ok-callback err-callback)
  (urbit-http-poke "graph-push-hook"
                   "graph-update"
                   action
                   ok-callback
                   err-callback))

;;
;; View Actions
;;

(defun urbit-graph-join (ship name)
  (urbit-graph-let-resource
   (urbit-graph-view-action "graph-join"
                            `((join ,resource
                                    (ship . ,ship))))))

(defun urbit-graph-delete (name)
  (let ((resource (urbit-graph-make-resource (ensig urbit-ship)
                                             name)))
    (urbit-graph-view-action "graph-delete"
                             `((delete ,resource)))))

(defun urbit-graph-leave (ship name)
  (urbit-graph-let-resource
   (urbit-graph-view-action "graph-leave"
                            `((leave ,resource)))))


;; TODO: what is to
(defun urbit-graph-groupify (ship name to-path)
  (urbit-graph-let-resource
   (urbit-graph-view-action "graph-groupify"
                            `((groupify ,resource (to . to))))))

;;
;; Store Actions
;;
(defun urbit-graph-add (ship name graph mark)
  (urbit-graph-let-resource
   (urbit-graph-store-action
    `((add-graph ,resource (graph . ,graph) (mark . ,mark))))))


;;
;; Hook Actions
;;
;; TODO: graph.ts has some pending logic in here
(defun urbit-graph-add-nodes (ship name nodes)
  (urbit-graph-let-resource
   (urbit-graph-hook-action
    `((add-nodes ,resource (nodes . ,nodes))))
   ;; Send the same event, with the ship desigged, to our local graph
   (urbit-graph-update-handler
    `((data
       (graph-update
        (add-nodes
         ,(urbit-graph-make-resource (desig ship)
                                     name)
         (nodes . ,nodes))))))))

(defun urbit-graph-add-node (ship name node)
  (urbit-graph-add-nodes ship name
                         (let ((index (alist-get 'index
                                                 (alist-get 'post node))))
                           (urbit-log "Adding node index %s" index)
                           `((index node)))))

(defun urbit-graph-remove-nodes (ship name indices)
  (urbit-graph-let-resource
   (urbit-graph-hook-action `((remove-nodes ,resource (indices . indices))))))

;;
;; Fetching
;;
(aio-defun urbit-graph-get-keys ()
  (let ((keys
         (aio-await
          (urbit-http-scry "graph-store" "/keys"))))
    ;; TODO: Our state pipeline doesn't know what to do with keys
    (urbit-graph-update-handler `((data . keys)))))

(aio-defun urbit-graph-get-wrapper (path)
  "Scries graph-store at PATH, and feeds the result to `urbit-graph-update-handler'"
  (urbit-graph-update-handler
   (car
    (aio-await
     (urbit-http-scry "graph-store" path)))))

(defun urbit-graph-get (ship name)
  "Get a graph at SHIP NAME."
  (urbit-graph-get-wrapper
   (format "/graph/%s/%s"
           (urbit-ensig ship)
           name)))

(defun urbit-graph-get-newest (ship name count &optional index)
  (urbit-http--let-if-nil ((index ""))
    (urbit-graph-get-wrapper
     (format "/newest/%s/%s/%s%s"
                                (urbit-ensig ship)
                                name
                                count
                                index))))

(defun urbit-graph-get-older-siblings (ship name count &optional index)
  (urbit-http--let-if-nil ((index ""))
    (urbit-graph-get-wrapper
     (format "/node-siblings/older/%s/%s/%s%s"
                                (urbit-ensig ship)
                                name
                                count
                                (urbit-graph-index-to-ud index)))))

(defun urbit-graph-get-younger-siblings (ship name count &optional index)
  (urbit-http--let-if-nil ((index ""))
    (urbit-graph-get-wrapper
     (format "/node-siblings/younger/%s/%s/%s%s"
                                (urbit-ensig ship)
                                name
                                count
                                (urbit-graph-index-to-ud index)))))

(defun urbit-graph-get-subset (ship name start end)
  (urbit-graph-get-wrapper
   (format "/graph-subset/%s/%s/%s/%s"
           ship
           name
           end
           start)))

(defun urbit-graph-get-node (ship name index)
  (urbit-graph-get-wrapper
   (format "/%s/%s%s"
           ship
           name
           (urbit-graph-index-to-ud index))))



(provide 'urbit-graph)

;;; urbit-graph.el ends here
