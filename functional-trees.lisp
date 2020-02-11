(defpackage :functional-trees
  (:nicknames :ft :functional-trees/functional-trees)
  (:use :common-lisp :alexandria :iterate :gmap)
  (:shadowing-import-from :fset
                          :@ :do-seq :seq :lookup :alist
                          :unionf :appendf :with :less :splice :insert :removef
			  ;; Shadowed set operations
			  :union :intersection :set-difference :complement
			  ;; Shadowed sequence operations
			  :first :last :subseq :reverse :sort :stable-sort
			  :reduce
			  :find :find-if :find-if-not
			  :count :count-if :count-if-not
			  :position :position-if :position-if-not
			  :remove :remove-if :remove-if-not
			  :substitute :substitute-if :substitute-if-not
			  :some :every :notany :notevery
                          ;; Additional stuff
                          :identity-ordering-mixin :serial-number
                          :compare :convert)
  (:shadow :subst :subst-if :subst-if-not)
  (:shadowing-import-from
   :cl :set :union :intersection :set-difference :complement)
  (:shadowing-import-from :alexandria :compose)
  (:import-from :uiop/utility :nest)
  (:import-from :closer-mop :slot-definition-name :class-slots)
  (:export :copy
           :node :transform :child-slots :data-slot :finger
           :path :transform-finger-to :residue
           :children
           :populate-fingers
           :map-tree
           :traverse-nodes
           :traverse-nodes-with-rpaths
           :node-equalp
           :swap)
  (:documentation
   "Prototype implementation of functional trees w. finger objects"))
(in-package :functional-trees)


;;;; Core functional tree definitions.

(deftype path ()
  `(and list (satisfies path-p)))

(defun path-p (list)
  (every (lambda (x)
           (typecase x
             ((integer 0) t)            ; Index into `children'.
             (symbol t)                 ; Name of scalar child-slot.
             ((cons (integer 0)         ; Non-scalar child-slot w/index.
                    (cons integer null))
              (<= (first x) (second x)))
             (t nil)))
         list))

(defgeneric copy (obj &key &allow-other-keys)
  (:documentation "Generic COPY method.") ; TODO: Extend from generic-cl?
  (:method ((obj t) &key &allow-other-keys) obj)
  (:method ((obj array) &key &allow-other-keys) (copy-array obj))
  (:method ((obj hash-table) &key &allow-other-keys) (copy-hash-table obj))
  (:method ((obj list) &key &allow-other-keys) (copy-list obj))
  (:method ((obj readtable) &key &allow-other-keys) (copy-readtable obj))
  (:method ((obj sequence) &key &allow-other-keys) (copy-seq obj))
  (:method ((obj symbol) &key &allow-other-keys) (copy-symbol obj)))

(defclass node (identity-ordering-mixin)
  ((transform :reader transform
              :initarg :transform
              :initform nil
              :type (or null node path-transform)
              :documentation "If non-nil, is either a PATH-TRANSFORM object
to this node, or the node that led to this node.")
   (child-slots :reader child-slots
                :initform nil
                :allocation :class)
   (data-slot :reader data-slot
              :initform nil
              :allocation :class)
   (finger :reader finger
           :initform nil
           :type (or null node finger)
           :documentation "A finger back to the root of the (a?) tree."))
  (:documentation "A node in a tree."))

;;; NOTE: We might want to propos a patch to FSet to allow setting
;;; serial-number with an initialization argument.
(defmethod initialize-instance :after
  ((node node) &key (serial-number nil serial-number-p) &allow-other-keys)
  (when serial-number-p
    (setf (slot-value node 'serial-number) serial-number)))

(defgeneric children (node)
  (:documentation "Return all children of NODE.")
  (:method ((node node))
    (apply #'append
           (mapcar (lambda (slot) (slot-value node slot)) (child-slots node)))))

(defgeneric data (node)
  (:documentation "Return the data of NODE.
If no `data-slot' is defined on NODE return itself.")
  (:method ((non-node t)) non-node)
  (:method ((node node))
    (if (data-slot node)
        (slot-value node (data-slot node))
        node)))

(defmethod transform :around ((n node))
  ;; Compute the PT lazily, when TRANSFORM is a node
  (let ((tr (call-next-method)))
    (if (typep tr 'node)
        (setf (slot-value n 'transform) (path-transform-of tr n))
        tr)))

;;; NOTE: There should be a way to chain together methods for COPY for
;;; classes and their superclasses, perhaps using the initialization
;;; infrastructure in CL for objects.
(defmethod copy ((node node) &rest keys)
  (nest
   (apply #'make-instance (class-name (class-of node)))
   (apply #'append keys)
   (mapcar (lambda (slot) (list (make-keyword slot) (slot-value node slot))))
   (mapcar #'slot-definition-name (class-slots (class-of node)))))

(defclass finger ()
  ((node :reader node :initarg :node
         :type node
         :initform (required-argument :node)
         :documentation "The node to which this finger pertains,
considered as the root of a tree.")
   (path :reader path :initarg :path
         :type path
         :initform (required-argument :path)
         :documentation "A list of nonnegative integer values
giving a path from node down to another node.")
   (residue :reader residue :initarg :residue
            :initform nil ;; (required-argument :residue)
            :type list
            :documentation "If this finger was created from another
finger by a path-transform, some part of the path may not have been
translated.  If so, this field is the part that could not be handled.
Otherwise, it is NIL.")
   (cache :accessor :node :accessor cache
         :documentation "Internal slot used to cache the lookup of a node."))
  (:documentation "A wrapper for a path to get to a node"))

;;; The Path should hold
;;; - a raw index into the children
;;; - a cons of child-slot and index

(defmethod slot-unbound ((class t) (f finger) (slot (eql 'cache)))
  ;; Fill in the NODE slot of finger F
  (let* ((node (node f))
         (path (path f)))
    (iter (for i in path)
          (unless (typep node 'node)
            (error "Path ~a not valid for tree rooted at ~a: ~a"
                   (path f) (node f) node))
          (destructuring-bind (slot . index)
              (etypecase i
                (cons i)
                (fixnum
                 (unless (= 1 (length (child-slots node)))
                   (error "numeric index ~a used with multiple child slots ~s"
                          i (child-slots node)))
                 (cons (first (child-slots node)) i)))
            (let ((children (slot-value node slot)))
              (unless (and (<= 0 index) (< index (length children)))
                (error "~a not a valid child index for ~a" index node))
              (setf node (elt children index)))))
    ;; This assignment is functionally ok, since it is assigned
    ;; only once when the cache is filled
    (setf (slot-value f 'cache) node)))

(defclass path-transform ()
  ((from
    :reader from :initarg :from
    :type node
    :initform (required-argument :from))
   (transforms :initarg :transforms
               :reader transforms
               :type list
               :documentation "A list of (<path-set> <path> <status>) triples
where <path-set> is a path set, <path> is the mapping of the initial path
in that <path-set>, and <status> is one of :live :dead. These should be
sorted into non-increasing order of length of <path>.  If missing, compute
from the source/target node pair, if possible."))
  (:documentation "An object used to rewrite fingers from one
tree to another."))

(defgeneric transform-finger-to (f p to)
  (:documentation "Converts a finger from one tree to another."))

(defgeneric successor (tree node)
  (:documentation "Return the successor of NODE in TREE.")
  (:method ((tree node) (node t)) (error "TODO: Implement `successor'.")))

(defgeneric predecessor (tree node)
  (:documentation "Return the predecessor of NODE in TREE.")
  (:method ((tree node) (node t)) (error "TODO: Implement `predecessor'.")))

;;; Around method to verify pre, post conditions
(defmethod transform-finger-to :around ((f finger) (p path-transform) (to node))
  (assert (eql (node f) (from p)))
  (let ((new-finger (call-next-method)))
    (assert (typep new-finger 'finger))
    new-finger))

(defmethod transform-finger-to ((f finger) (p path-transform) (to node))
  (multiple-value-bind (new-path residue)
      (transform-path (path f) (transforms p))
    (make-instance 'finger :path new-path
                   :node to :residue residue)))

(defun transform-path (path transforms)
  ;; This is inefficient, and is just for demonstration
  ;; In the real implementation, the segments are blended together
  ;; into a trie
  (let ((len (length path)))
    (iter (for (segment new-initial-segment status) in transforms)
          (when (and (>= len (length segment))
                     (every (lambda (i i-set)
                              (or (eql i i-set)
                                  (and (consp i-set)
                                       (integerp i)
                                       (<= (car i-set) i (cadr i-set)))))
                            path segment))
            (return
              (let ((new-segment
                     (loop for i in path
                        for init in new-initial-segment
                        for p in path
                        collect (if (consp i)
                                    (+ init (- p (car i)))
                                    init))))
                (if (< len (length new-initial-segment))
                    (append new-segment (subseq new-initial-segment len)
                            (subseq path (length segment)))
                    (ecase status
                      (:live (append new-segment
                                     (subseq path (length segment))))
                      (:dead (values new-segment
                                     (subseq path (length new-segment)))))))))
          (finally (return path)))))

(defgeneric transform-finger (finger node &key error-p)
  (:documentation "Transforms FINGER, producing a new finger that
points through the root NODE.  NODE must be derived from the tree
that FINGER is pointed through."))

(defmethod transform-finger ((f finger) (node node) &key (error-p t))
  (declare (ignore error-p)) ;; for now
  (let ((node-of-f (node f)))
    (labels ((%transform (x)
               (cond
                 ((eql x node-of-f) f)
                 ((null x)
                  ;; As an alternative, create a fresh path transform
                  ;; from the root for f to node, and use that instead
                  ;; However, we'd want to cache that somehow.
                  (error "Cannot find path from ~a to ~a"
                         node-of-f node))
                 (t
                  (let ((transform (transform x)))
                    (transform-finger-to
                     (%transform (from transform))
                     transform x))))))
      (%transform node))))

(defun populate-fingers (root)
  "Walk tree, creating fingers back to root."
  (traverse-nodes-with-rpaths
   root
   (lambda (n rpath)
     ;; This is the only place this slot should be
     ;; assigned, which is why there's no writer method.
     (unless (finger n)
       (setf (slot-value n 'finger)
             (make-instance 'finger :node root :path (reverse rpath))))
     n))
  root)

;;; This expensive function is used in testing and in FSet
;;; compatibility functions.  It computes the path leading from ROOT
;;; to NODE, or signals an error if it cannot be found.
(defun path-of-node (root node)
  (labels ((%search (path n)
             (when (eql n node)
               (return-from path-of-node
                 (nreverse (if (= 1 (length (child-slots node)))
                               (mapcar #'cdr path)
                               path))))
             (typecase n
               (node
                (iter (for s in (child-slots node))
                      (iter (for i from 0)
                            (for c in (slot-value n s))
                            (%search (cons (cons s i) path) c)))))))
    (%search nil root))
  (error "Cannot find ~a in ~a" node root))

;;; To add: algorithm for extracting a  path transform from
;;; a set of rewrites (with var objects).  Also, conversion of the
;;; transform set to a trie.

(defgeneric map-tree (function tree)
  (:documentation
   "Map FUNCTION over TREE returning the result as a (potentially) new tree.")
  (:method (function (object t))
    (funcall function object))
  (:method (function (object cons))
    (cons (map-tree function (car object))
          (map-tree function (cdr object))))
  (:method (function (node node))
    (copy (nest
           (multiple-value-bind (value stop) (funcall function node))
           (if stop value)
           (apply #'copy value)
           (apply #'append)
           (mapcar (lambda (slot)
                     (when-let ((it (slot-value node slot)))
                       (list (make-keyword slot)
                             (mapcar (curry #'map-tree function) it))))
                   (child-slots node)))
          ;; Set the transform field of the result to the old node.
          :transform node)))

(defgeneric traverse-nodes (root fn)
  (:documentation 
  "Apply FN at every node below ROOT, in preorder, left to right
   If FN returns NIL, stop traversal below this point.  Returns NIL."))

(defmethod traverse-nodes :around ((node node) fn)
  (when (funcall fn node)
    (call-next-method)))

(defmethod traverse-nodes ((node node) fn)
  (dolist (c (children node))
    (traverse-nodes c fn)))

(defmethod traverse-nodes ((node t) (fn t)) t)

(defgeneric traverse-nodes-with-rpaths (root fn)
  (:documentation
   "Apply FN at every node below ROOT, in preorder, left to right.
   Also pass to FN a list of indexes that is the reverse of the
   path from ROOT to the node.  If FN returns NIL, stop traversal
   below this point.  Returns NIL."))

(defmethod traverse-nodes-with-rpaths ((node null) fn) nil)

(defmethod traverse-nodes-with-rpaths ((node node) fn)
  (traverse-nodes-with-rpaths* node fn nil))

(defgeneric traverse-nodes-with-rpaths* (root fn rpath)
  (:documentation "Internal method to implement traverse-nodes-with-rpaths"))  

(defmethod traverse-nodes-with-rpaths* :around ((node node) fn rpath)
  (when (funcall fn node rpath)
    (call-next-method)))

(defmethod traverse-nodes-with-rpaths* ((node node) fn rpath)
  (iter (for i from 0)
        (for c in (children node))
        (traverse-nodes-with-rpaths* c fn (cons i rpath)))
  nil)

(defmethod traverse-nodes-with-rpaths* ((node t) (fn t) (rpath t)) nil)

;;; To traverse fields aside from CHILDREN, write methods
;;; for the particular class for these functions that explicitly
;;; traverse those fields, then (if none returned NIL) performs
;;; (call-next-method) to the general methods for node.


(defgeneric node-valid (node)
  (:documentation "True if the tree rooted at NODE have EQL unique
serial-numbers, and no node occurs on two different paths in the tree"))

(defmethod node-valid ((node node))
  (let ((serial-number-table (make-hash-table)))
    (traverse-nodes node (lambda (n)
                           (let ((serial-number (serial-number n)))
                             (when (gethash serial-number serial-number-table)
                               (return-from node-valid nil))
                             (setf (gethash serial-number serial-number-table)
                                   n))))
    t))

(defun store-nodes (node table)
  (traverse-nodes node (lambda (n) (setf (gethash (serial-number n) table) n))))

(defgeneric nodes-disjoint (node1 node2)
  (:documentation "Return true if NODE1 and NODE2 do not share
any serial-number"))

(defmethod nodes-disjoint ((node1 node) (node2 node))
  (let ((serial-number-table (make-hash-table)))
    ;; Populate serial-number table
    (store-nodes node1 serial-number-table)
    ;; Now check for collisions
    (traverse-nodes
     node2 (lambda (n)
             (when (gethash (serial-number n) serial-number-table)
               (return-from nodes-disjoint nil))
             t))
    t))

(defgeneric node-can-implant (root at-node new-node)
  (:documentation "Check if new-node can the subtree rooted at at-node
below ROOT and produce a valid tree."))

(defmethod node-can-implant ((root node) (at-node node) (new-node node))
  (let ((serial-number-table (make-hash-table)))
    ;; Populate serial-number table
    (traverse-nodes
     root
     (lambda (n)
       ;; Do not store serial-numbers at or below at-node
       (unless (eql n at-node)
         (setf (gethash (serial-number n) serial-number-table) n))))
    ;; Check for collisions
    (traverse-nodes
     new-node
     (lambda (n)
       (when (gethash (serial-number n) serial-number-table)
         (return-from node-can-implant nil))
       t))
    t))

(defun lexicographic-< (list1 list2)
  "Lexicographic comparison of lists of reals or symbols
Symbols are considered to be less than reals, and symbols
are compared with each other using fset:compare"
  (loop
     (unless list1
       (return (not (null list2))))
     (unless list2
       (return nil))
     (let ((c1 (pop list1))
           (c2 (pop list2)))
       (cond
         ((symbolp c1)
          (unless (symbolp c2) (return t))
          (unless (eql c1 c2)
            (return (eql (compare c1 c2) :less))))
         ((symbolp c2) (return nil))
         ((<= c1 c2)
          (when (< c1 c2)
            (return t)))
         (t (return nil))))))

(defun prefix? (p1 p2)
  "True if list P1 is a prefix of P2"
  (loop (cond
          ((null p1) (return t))
          ((null p2) (return nil))
          ((eql (car p1) (car p2))
           (pop p1)
           (pop p2))
          (t (return nil)))))

(defgeneric path-transform-of (from-node to-node)
  (:documentation "Produce a path transform that maps FROM-NODE to TO-NODE"))

;;; Structure used in computation of path-transform-of
(defstruct pto-data
  ;; Node in the source tree
  from
  ;; Node in the target tree
  to
  ;; Path from root of source tree to FROM node
  from-path
  ;; Path from root of target tree to TO node
  to-path)

(defmethod path-transform-of ((from node) (to node))
  (let ((table (make-hash-table)))
    (traverse-nodes-with-rpaths
     from
     (lambda (n rpath)
       (setf (gethash (serial-number n) table)
             (make-pto-data :from n :from-path (reverse rpath)))))
    #+debug (format t "Table (1): ~a~%" table)
    ;; Now find nodes that are shared
    (traverse-nodes-with-rpaths
     to
     (lambda (n rpath)
       (let* ((entry (gethash (serial-number n) table)))
         (or (not entry)
             (progn
               (setf (pto-data-to entry) n
                     (pto-data-to-path entry) (reverse rpath))
               ;; Stop recursion when this is common
               (not (eql (pto-data-from entry) n)))))))
    ;; Construct mapping
    (let (mapping)
      (maphash (lambda (n pd)
                 (declare (ignorable n))
                 #+debug (format t "Maphash ~a, ~a~%" n pd)
                 (when (pto-data-to pd)
                   (push
                    (list (pto-data-from-path pd)
                          (pto-data-to-path pd))
                    mapping)))
               table)
      #+debug (format t "Mapping:~%~A~%" mapping)
      ;; Mapping is now a list of (<old path> <new path>) lists
      ;; Sort this into increasing order of <old path>, lexicographically
      (setf mapping (sort mapping #'lexicographic-< :key #'car))
      #+debug (format t "Sorted mapping:~%~A~%" mapping)

      (let ((sorted-result (path-transform-compress-mapping mapping)))
        (make-instance
         'path-transform
         :from from
         :transforms (mapcar (lambda (p) (append p (list :live)))
                             sorted-result))))))

;;; TODO: enhance this compression so that paths that differ
;;; only in the final index are compressed into "range" paths.
(defun path-transform-compress-mapping (mapping)
  "Internal function used to remove redundancy from a set
   of path mappings."
  (let (stack result)
    (iter (for (old new) in mapping)
          #+debug
          (progn 
            (format t "(old new) = ~a~%" (list old new))
            (format t "stack = ~a~%" stack)
            (format t "result = ~a~%" result))
          (iter (until (or (null stack)
                           (prefix? (caar stack) old)))
                (push (pop stack) result))
          (if (null stack)
              (push (list old new) stack)
              (let ((len (length (caar stack))))
                (if (and (prefix? (caar stack) old)
                         (equal new (append (cadr stack) (subseq old len))))
                    ;; This rewrite is subsumed by
                    ;; the one on the stack -- do nothing
                    nil
                    ;; Otherwise, push a new entry
                    (push (list old new) stack)))))
    (stable-sort (revappend stack result) #'> :key #'(lambda (x) (length (car x))))))

(defgeneric node-equalp (node1 node2)
  (:documentation "Check that two nodes are the same tree")
  (:method ((node1 node) (node2 node))
    (and (eql (serial-number node1) (serial-number node2))
         (let ((c1 (children node1))
               (c2 (children node2)))
           (and (eql (length c1) (length c2))
                (every #'node-equalp c1 c2)))))
  (:method (node1 node2) (equal node1 node2)))


;;;; FSet interoperability.

;;; Define `lookup' methods to work with FSet's `@' macro.
(defmethod lookup ((node t) (path null)) node)
(defmethod lookup ((node node) (path cons))
  (etypecase path
    (proper-list
     (lookup (lookup node (car path)) (cdr path)))
    (cons
     (destructuring-bind (slot . i) path
       (elt (slot-value node slot) i)))))
(defmethod lookup ((node node) (finger finger))
    (let ((new-finger (transform-finger finger node)))
      (values (lookup node (path new-finger)) (residue new-finger))))
(defmethod lookup ((node node) (i integer))
  (elt (children node) i))

;;; NOTE: The following `with', `less', and `splice' are all very
;;;       formulaic.  Perhaps they could share implementation
;;;       structure with independent `descend' methods.

(defmethod with ((tree node) path &optional (value nil valuep))
  "Adds VALUE (value2) at PATH (value1) in TREE."
  (fset::check-three-arguments valuep 'with 'node)
  ;; Walk down the path creating new trees on the way up.
  (labels ((descend (children index path)
             (append (subseq children 0 index)
                     (list (-with (nth index children) path))
                     (subseq children (1+ index))))
           (-with (node path)
             (nest (if (emptyp path) value)
                   (let ((index (car path))))
                   (apply #'copy node)
                   (mappend (lambda (slot)
                              (when-let ((children (slot-value node slot)))
                                (list (make-keyword slot)
                                      (descend children index (cdr path)))))
                            (child-slots node)))))
    (copy (-with tree path) :transform tree)))

(defmethod with ((tree node) (location node) &optional (value nil valuep))
  (fset::check-three-arguments valuep 'with 'node)
  (with tree (path-of-node tree location) value))

(defmethod less ((tree node) path &optional (arg2 nil arg2p))
  (declare (ignore arg2))
  (fset::check-two-arguments arg2p 'less 'node)
  (labels ((descend (children index path)
             (append (subseq children 0 index)
                     (unless (emptyp path)
                       (list (less- (nth index children) path)))
                     (subseq children (1+ index))))
           (less- (node path)
             (nest (let ((index (car path))))
                   (apply #'copy node)
                   (mappend (lambda (slot)
                              (when-let ((children (slot-value node slot)))
                                (list (make-keyword slot)
                                      (descend children index (cdr path)))))
                            (child-slots node)))))
    (less- tree path)))

(defmethod less ((tree node) (location node) &optional (arg2 nil arg2p))
  (declare (ignore arg2))
  (fset::check-two-arguments arg2p 'less 'node)
  (less tree (path-of-node tree location)))

(defmethod splice ((tree node) (path list) (values t))
  (insert tree path (list values)))
(defmethod splice ((tree node) (path list) (values list))
  (labels ((descend (children index path)
             (append (subseq children 0 index)
                     (if (emptyp path)
                         values
                         (list (splice- (nth index children)
                                        path)))
                     (subseq children index)))
           (splice- (node path)
             (nest (let ((index (car path))))
                   (apply #'copy node)
                   (mappend (lambda (slot)
                              (when-let ((children (slot-value node slot)))
                                (list (make-keyword slot)
                                      (descend children index (cdr path)))))
                            (child-slots node)))))
    (splice- tree path)))

(defmethod splice ((tree node) (location node) value)
  (splice tree (path-of-node tree location) value))

(defmethod insert ((tree node) (path list) value)
  (splice tree path (list value)))

(defmethod insert (tree (path node) value)
  (splice tree (path-of-node tree path) (list value)))

(defgeneric swap (tree location-1 location-2)
  (:documentation "Swap the contents of LOCATION-1 and LOCATION-2 in TREE.")
  (:method ((tree node) (location-1 list) (location-2 list))
    (let ((value-1 (@ tree location-1))
          (value-2 (@ tree location-2)))
      (with (with tree location-1 value-2) location-2 value-1)))
  (:method ((tree node) (location-1 node) location-2)
    (swap tree (path-of-node tree location-1) location-2))
  (:method ((tree node) location-1 (location-2 node))
    (swap tree location-1 (path-of-node tree location-2))))

(defmethod size ((other t)) 0)
(defmethod size ((node node))
  (1+ (reduce #'+ (mapcar #'size (children node)))))

(defmethod print-object ((obj node) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (obj stream :type t)
        (format stream "~a ~a" (serial-number obj) (convert 'list obj)))))

(defmethod print-object ((obj finger) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (obj stream :type t)
        (format stream "~a ~a~@[ ~a~]"
                (node obj) (path obj) (residue obj)))))

(defmethod print-object ((obj path-transform) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (obj stream :type t)
        (format stream "~a ~a"
                (transforms obj) (from obj)))))


;;;; FSET conversion operations

;;; NOTE: All indications are this doesn't work yet.
(def-gmap-arg-type :node (node)
  "Yields the nodes of NODE in preorder."
  `((,node)
    #'endp
    #'(lambda (nodes) (append (children (car nodes)) (cdr nodes)))
    #'cddr))

(defmethod convert ((to-type (eql 'list)) (node node)
                    &key (value-fn #'data) &allow-other-keys)
  "Convert NODE of type node to a list."
  (declare (optimize (speed 3)))
  (setf value-fn (coerce value-fn 'function))
  (labels ((convert- (node)
             (declare (type function value-fn))
             (if (typep node 'node)
                 (cons (funcall value-fn node)
                       (mapcar #'convert- (children node)))
                 node)))
    (convert- node)))

(defmethod convert ((to-type (eql 'list)) (finger finger)
                    &key &allow-other-keys)
  (let ((cached (cache finger)))
    (if (typep cached 'node)
        (convert to-type cached)
        cached)))

(defmethod convert ((to-type (eql 'alist)) (node node)
                    &key (value-fn nil value-fn-p) &allow-other-keys)
  (convert
   'list node :value-fn
   (if value-fn-p value-fn
       (let ((slots
              (nest
               (remove-if
                (rcurry #'member '(serial-number transform finger children)))
               (mapcar #'slot-definition-name (class-slots (class-of node))))))
         (lambda (node)
           (apply #'append
                  (mapcar (lambda (slot)
                            (when-let ((val (slot-value node slot)))
                              (list (cons (make-keyword slot) val))))
                          slots)))))))


;;; FSET sequence operations (+ two) for functional tree.
(defgeneric substitute-with (predicate sequence &key &allow-other-keys)
  (:documentation
   "Substitute elements of SEQUENCE with result of PREDICATE when non-nil.
If secondary return value of PREDICATE is non-nil force substitution
  with primary value even if it is nil.")
  (:method (predicate (sequence sequence) &key &allow-other-keys )
    (let ((predicate (coerce predicate 'function)))
      (map (type-of sequence)
           (lambda (element)
             (multiple-value-bind (value force)
                 (funcall predicate element)
               (if force value (or value element))))
           sequence)))
  (:method (predicate (seq seq) &key &allow-other-keys &aux result)
    (let ((predicate (coerce predicate 'function)))
      (do-seq (element seq)
        (multiple-value-bind (value force)
            (funcall predicate element)
          (push (if force value (or value element)) result)))
      (convert 'seq (nreverse result)))))

(defmethod reduce (fn (node node) &rest rest &key &allow-other-keys)
  (apply #'reduce fn (flatten (convert 'list node)) rest))

(defmethod find (item (node node) &rest rest &key &allow-other-keys)
  (apply #'find item (flatten (convert 'list node)) rest))

(defmethod find-if (predicate (node node) &rest rest &key &allow-other-keys)
  (apply #'find-if predicate (flatten (convert 'list node)) rest))

(defmethod find-if-not (predicate (node node) &rest rest &key &allow-other-keys)
  (apply #'find-if-not predicate (flatten (convert 'list node)) rest))

(defmethod count (item (node node) &rest rest &key &allow-other-keys)
  (apply #'count item (flatten (convert 'list node)) rest))

(defmethod count-if (predicate (node node) &rest rest &key &allow-other-keys)
  (apply #'count-if predicate (flatten (convert 'list node)) rest))

(defmethod count-if-not (predicate (node node)
                         &rest rest &key &allow-other-keys)
  (apply #'count-if-not predicate (flatten (convert 'list node)) rest))

(defmethod position (item (node node) &key (test #'equalp) (key #'data key-p)
                                        &allow-other-keys)
  (apply #'position-if (curry (coerce test 'function) item) node
         (when key-p (list :key key))))

(defmethod position-if (predicate (node node)
                        &key from-end end start test-not test
                          (key #'data))
  (assert (notany #'identity from-end end start test-not test)
          (from-end end start test-not test)
          "TODO: implement support for ~a key in `position-if'"
          (cdr (find-if #'car
                        (mapcar #'cons
                                (list from-end end start test-not test)
                                '(from-end end start test-not test)))))
  (when key (setf key (coerce key 'function)))
  (labels
      ((check (item) (funcall predicate (if key (funcall key item) item)))
       (position- (predicate node path)
         (nest (if (not (typep node 'node))
                   (when (check node)
                     (return-from position-if (nreverse path))))
               (if (check node)
                   (return-from position-if (nreverse path)))
               (let* ((slots (child-slots node))
                      (single-child (= 1 (length slots)))))
               (mapc (lambda (slot)
                       (let ((children (slot-value node slot)))
                         (mapc (lambda (child index)
                                 (nest
                                  (position- predicate child)
                                  (if single-child (cons index path))
                                  (cons (cons (make-keyword slot) index) path)))
                               children
                               (iota (length children)))))
                     slots))))
    (position- (coerce predicate 'function) node nil)
    nil))

(defmethod position-if-not (predicate (node node)
                            &key (key #'data key-p) &allow-other-keys)
  (apply #'position-if (complement predicate) node
         (when key-p (list :key key))))

(defmethod remove (item (node node)
                   &key (test #'equalp) (key #'data key-p) &allow-other-keys)
  (apply #'remove-if (curry (coerce test 'function) item) node
         (when key-p (list :key key))))

(defmethod remove-if (predicate (node node) &key (key #'data) &allow-other-keys)
  (when key (setf key (coerce key 'function)))
  (labels
      ((check (node)
         (funcall predicate (if key (funcall (the function key) node) node)))
       (remove- (predicate node)
         (nest (if (not (typep node 'node))
                   (if (check node)
                       (values nil t)
                       (values (list node) nil)))
               (if (check node) (values nil t))
               (let* ((modifiedp nil)
                      (new-children
                       (mappend
                        (lambda (slot)
                          (when-let ((children (slot-value node slot)))
                            (list (make-keyword slot)
                                  (mappend
                                   (lambda (child)
                                     (multiple-value-bind (new was-modified-p)
                                         (remove- predicate child)
                                       (when was-modified-p (setf modifiedp t))
                                       new))
                                   children))))
                        (child-slots node)))))
               (if (not modifiedp) (values (list node) nil))
               (values (list (apply #'copy node new-children)) t))))
    (car (remove- (coerce predicate 'function) node))))

(defmethod remove-if-not (predicate (node node)
                          &key (key #'data key-p) &allow-other-keys)
  (apply #'remove-if (complement predicate) node (when key-p (list :key key))))

(defmethod substitute
    (newitem olditem (node node)
     &key (test #'equalp) (key #'data key-p) &allow-other-keys)
  (apply #'substitute-if newitem (curry (coerce test 'function) olditem) node
         :test test (when key-p (list :key key))))

(defmethod substitute-if
    (newitem predicate (node node)
     &key (copy nil copyp) (key #'data key-p) &allow-other-keys)
  (when copyp (setf copy (coerce copy 'function)))
  (setf predicate (coerce predicate 'function))
  (apply #'substitute-with
         (lambda (item)
           (when (funcall predicate item)
             (values (if copyp (funcall copy newitem) newitem) t)))
         node (when key-p (list :key key))))

(defmethod substitute-if-not (newitem predicate (node node)
                              &key (key #'data key-p)
                                &allow-other-keys)
  (apply #'substitute-if newitem
         (complement predicate) node (when key-p (list :key key))))

(defgeneric subst (new old tree &key key test test-not)
  (:documentation "If TREE is a cons, this simply calls `cl:subst'.
Also works on a functional tree node.")
  (:method (new old (tree cons)
            &key (key nil key-p) (test nil test-p) (test-not nil test-not-p))
    (apply #'cl:subst new old tree
           `(,@(when key-p (list :key key))
               ,@(when test-p (list :test test))
               ,@(when test-not-p (list :test-not test-not)))))
  (:method (new old (tree node) &rest rest &key &allow-other-keys)
    (apply #'substitute new old tree rest)))

(defgeneric subst-if (new test tree &key key)
  (:documentation "If TREE is a cons, this simply calls `cl:subst-if'.
Also works on a functional tree node.")
  (:method (new test (tree cons) &key (key nil key-p))
    (apply #'cl:subst-if new test tree (when key-p (list :key key))))
  (:method (new test (tree node) &rest rest &key &allow-other-keys)
    (apply #'substitute-if new test tree rest)))

(defgeneric subst-if-not (new test tree &key key)
  (:documentation "If TREE is a cons, this simply calls `cl:subst-if'.
Also works on a functional tree node.")
  (:method (new test tree &key (key nil key-p))
    (apply #'subst-if new (complement test) tree (when key-p (list :key key)))))

(defmethod substitute-with (function (node node)
                            &key (key #'data) &allow-other-keys)
  (when key (setf key (coerce key 'function)))
  (labels
      ((check (node)
         (funcall function (if key (funcall (the function key) node) node)))
       (substitute- (predicate node)
         (nest (if (not (typep node 'node))
                   (multiple-value-bind (value force) (check node)
                     (if (or force value)
                         (values (list value) t)
                         (values (list node) nil))))
               (multiple-value-bind (value force) (check node))
               (if (or force value) (values (list value) t))
               (let* ((modifiedp nil)
                      (new-children
                       (mappend
                        (lambda (slot)
                          (when-let ((children (slot-value node slot)))
                            (list (make-keyword slot)
                                  (mappend
                                   (lambda (child)
                                     (multiple-value-bind (new was-modified-p)
                                         (substitute- predicate child)
                                       (when was-modified-p (setf modifiedp t))
                                       new))
                                   children))))
                        (child-slots node))))
                 (if (not modifiedp)
                     (values (list node) nil)
                     (values (list (apply #'copy node new-children)) t))))))
    (car (substitute- (coerce function 'function) node))))