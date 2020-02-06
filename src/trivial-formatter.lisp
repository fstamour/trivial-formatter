(in-package :cl-user)
(defpackage :trivial-formatter
  (:use :cl)
  (:export
    ;; Main api
    #:fmt
    ;; Useful helpers
    #:read-as-code
    #:print-as-code
    ))
(in-package :trivial-formatter)

;;;; FMT
(declaim (ftype (function ((or symbol string asdf:system)
                           &optional
                           (member nil :append :supersede :rename :error :new-version
                                   :rename-and-delete :overwrite))
                          (values null &optional))
                fmt))
(defun fmt (system &optional(if-exists nil supplied-p))
  (asdf:load-system system)
  (dolist (component (asdf:component-children (asdf:find-system system)))
    (if supplied-p
      (with-open-file(s (asdf:component-pathname component
                                                 :direction :output
                                                 :if-does-not-exist :create
                                                 :if-exists if-exists))
        (debug-printer component))
      (debug-printer component))))

;;;; READ-AS-CODE
(declaim (ftype (function (&optional
                            (or null stream)
                            boolean
                            T
                            boolean)
                          (values t &optional))
                read-as-code))
(defun read-as-code (&optional
                      stream
                      (eof-error-p T)
                      (eof-value nil)
                      (recursive-p nil))
  (let* ((*readtable*
           (named-readtables:find-readtable 'as-code))
         (*standard-input*
           (or stream *standard-input*))
         (char
           (peek-char t nil eof-error-p eof-value)))
    (if (eq char eof-value)
      eof-value
      (if(get-macro-character char)
        (read *standard-input* eof-error-p eof-value recursive-p)
        (let*((notation
                (read-as-string:read-as-string nil eof-error-p eof-value recursive-p)))
          (handler-case(let((value(read-from-string notation)))
                         (if (valid-value-p value)
                           value
                           (make-broken-symbol :notation notation)))
            #+ecl
            (error(c)
              (if(search "There is no package with the name"
                         (princ-to-string c))
                (make-broken-symbol :notation notation)
                (error c)))
            (package-error()
              (make-broken-symbol :notation notation))))))))

(defun valid-value-p(thing)
  (or (not(symbolp thing))
      (keywordp thing)
      (null(symbol-package thing))
      (nth-value 1 (find-symbol (symbol-name thing)))))

;;;; META-OBJECT
;;; DOT
(defstruct dot)
(defmethod print-object ((dot dot) stream)
  (princ #\. stream))

;;; COMMENT
(defstruct comment content)
(defstruct (line-comment (:include comment)))
(defmethod print-object ((c line-comment)stream)
  (if (uiop:string-prefix-p #\; (comment-content c))
    (format stream "~:@_;~A" (comment-content c))
    (format stream "; ~A" (comment-content c)))
  (pprint-newline :mandatory stream)
  (write-char #\null stream))
(defstruct (block-comment (:include comment)))
(defmethod print-object((c block-comment) stream)
  (format stream "~A" (comment-content c)))

;;; CONDITIONAL
(defstruct conditional
  char
  condition)
(defmethod print-object ((c conditional) stream)
  (format stream "~_#~A~A"
          (conditional-char c)
          (conditional-condition c)))

;;; BROKEN-SYMBOL
(defstruct broken-symbol
  notation)
(defmethod print-object ((symbol broken-symbol)stream)
  (write-string (broken-symbol-notation symbol) stream))

;;; READ-TIME-EVAL
(defstruct read-time-eval
  form)
(defmethod print-object((form read-time-eval)stream)
  (format stream "~<#.~;~^~@{~A~^~:@_~}~:>"
          (uiop:split-string (prin1-to-string (read-time-eval-form form))
                             :separator '(#\newline))))

;;; SHARED-OBJECT
(defstruct shared-object number exp)
(defmethod print-object((obj shared-object)stream)
  (format stream "#~D=~S"
          (shared-object-number obj)
          (shared-object-exp obj)))

;;; SHARED-REFERENCE
(defstruct shared-reference number)
(defmethod print-object((ref shared-reference)stream)
  (format stream "#~D#" (shared-reference-number ref)))

;;;; MACRO CHARS
(defun |dot-reader| (stream character)
  (declare(ignore stream character))
  (make-dot))

(defun |paren-reader|(stream character)
  (declare(ignore character))
  (loop :for char = (peek-char t stream)
        ;; end check.
        :if (char= #\) char)
        :do (read-char stream)
        (loop-finish)
        ;; The default.
        :else :collect (read-as-code stream t t t)))

(defun |line-comment-reader| (stream character)
  (declare (ignore character))
  (make-line-comment :content(string-trim " "(read-line stream))))

(defun |block-comment-reader| (stream number character)
  (make-block-comment :content (funcall #'read-as-string::|#\|reader| stream number character)))

(defun |#+-reader|(stream character number)
  (when number
    (warn "A numeric argument is ignored in #~A~A."
          number character))
  (make-conditional :char character
                    :condition (read-as-code stream)))

(defun |#.reader|(stream character number)
  (declare(ignore character))
  (when number
    (warn "A numeric argument is ignored in read time eval."))
  (make-read-time-eval :form (read-as-code stream t t t)))

(defun |#=reader|(stream character number)
  (declare(ignore character))
  (make-shared-object :number number :exp (read-as-code stream)))

(defun |##reader|(stream character number)
  (declare(ignore stream character))
  (make-shared-reference :number number))

;;;; NAMED-READTABLE
(named-readtables:defreadtable as-code
  (:merge :common-lisp)
  (:macro-char #\( '|paren-reader|)
  (:macro-char #\. '|dot-reader| t)
  (:macro-char #\; '|line-comment-reader|)
  (:dispatch-macro-char #\# #\| '|block-comment-reader|)
  (:dispatch-macro-char #\# #\+ '|#+-reader|)
  (:dispatch-macro-char #\# #\- '|#+-reader|)
  (:dispatch-macro-char #\# #\. '|#.reader|)
  (:dispatch-macro-char #\# #\= '|#=reader|)
  (:dispatch-macro-char #\# #\# '|##reader|)
  )

;;;; DEBUG-PRINTER
(defun file-exp(pathname)
  (with-open-file(input pathname)
    (loop :with tag = '#:end
          :for exp = (read-as-code input nil tag)
          :until (eq exp tag)
          :collect exp)))

(defun debug-printer (component)
  (loop :for (exp . rest) :on (file-exp (asdf:component-pathname component))
        :do (when(and (comment-p exp)
                      (not (uiop:string-prefix-p #\; (comment-content exp))))
              (write-char #\space))
        (print-as-code exp)
        (typecase exp
          (block-comment
            (format t "~2%"))
          (line-comment
            (terpri)
            (when(not (comment-p (car rest)))
              (terpri)))
          (conditional
            (terpri))
          (t
            (typecase (car rest)
              (null)
              (line-comment
                (if(uiop:string-prefix-p #\; (comment-content (car rest)))
                  (format t "~2%")))
              (t
                (format t "~2%")))))))

;;;; PRETTY PRINTERS
(defun shortest-package-name (package)
  (reduce (lambda(champion challenger)
            (if(< (length champion)
                  (length challenger))
              champion
              challenger))
          (cons (package-name package)
                (package-nicknames package))))

(defun symbol-printer (stream object)
  (let((default-style
         (let((*print-pprint-dispatch*
                (copy-pprint-dispatch nil)))
           (prin1-to-string object))))
    (if (or (null (symbol-package object))
            (eq #.(find-package :keyword)
                (symbol-package object))
            (nth-value 1 (find-symbol (symbol-name object))))
      (write-string default-style stream)
      (progn
        (write-string (string-downcase
                        (shortest-package-name
                          (symbol-package object)))
                      stream)
        (write-string default-style
                      stream
                      :start
                      ;; Please do not ever use collon as package name!
                      (position #\: default-style))))))

(defun pprint-handler-case(stream exp &rest noise)
  (declare(ignore noise))
  (pprint-logical-block(stream exp :prefix "(" :suffix ")")
    (write (pprint-pop) :stream stream)
    (pprint-indent :block 3 stream)
    (pprint-exit-if-list-exhausted)
    (write-char #\space stream)
    (pprint-newline :fill stream)
    (write (pprint-pop) :stream stream)
    (pprint-exit-if-list-exhausted)
    (pprint-indent :block 1 stream)
    (pprint-newline :mandatory stream)
    (loop :for form = (pprint-pop)
          :if (atom form)
          :do (write form :stream stream)
          :else :if (= 1 (length form))
          :do (format stream "~W" form)
          :else :if (= 2 (length form))
          :do (apply #'format stream "(~W ~:A)" form)
          :else :do (apply #'format stream "(~1:I~W ~:A~^~:@_~@{~W~^ ~@_~})" form)
          :do(pprint-exit-if-list-exhausted)
          (pprint-indent :block 1 stream)
          (pprint-newline :mandatory stream))))

(defun pprint-define-condition(stream exp &rest noise)
  (declare(ignore noise))
  (pprint-logical-block(stream exp :prefix "(" :suffix ")")
    (flet((output()
            (write (pprint-pop) :stream stream)
            (pprint-exit-if-list-exhausted)
            (write-char #\space stream)))
      (output) ; operater
      (output) ; name
      (pprint-indent :block 3 stream)
      (format stream "~@_~:<~@{~W~^ ~}~:>" (pprint-pop)) ; superclasses
      (pprint-exit-if-list-exhausted)
      (pprint-indent :block 0 stream)
      (write-char #\space stream)
      (format stream "~:_~:<~^~W~^~_~:>" (pprint-pop)) ; slots
      (pprint-exit-if-list-exhausted)
      (pprint-newline :linear stream)
      (write-char #\space stream)
      (loop (write (pprint-pop) :stream stream)
            (pprint-exit-if-list-exhausted)
            (pprint-newline :mandatory stream)))))

(defun pprint-linear-elt (stream exp &rest noise)
  (declare(ignore noise))
  (setf stream (or stream *standard-output*))
  (format stream "~:<~W~^~1:I ~@{~W~^ ~_~}~:>" exp))

(defparameter *pprint-dispatch*
  (let((*print-pprint-dispatch*
         (copy-pprint-dispatch)))

    (set-pprint-dispatch '(eql #\space)
                         (lambda(stream object)
                           (format stream "#\\~:C" object)))

    (set-pprint-dispatch 'symbol 'symbol-printer)

    (set-pprint-dispatch '(cons (member handler-case)) 'pprint-handler-case)
    (set-pprint-dispatch '(cons (member loop)) 'pprint-extended-loop)
    (set-pprint-dispatch '(cons (member define-condition)) 'pprint-define-condition)
    (set-pprint-dispatch '(cons (member or and)) 'pprint-linear-elt)

    *print-pprint-dispatch*))

;;;; PRINT-AS-CODE
(defun split-to-lines (string)
  (mapcan (lambda(line)
            (setf line (remove #\nul
                               (ppcre:regex-replace #.(format nil "~C " #\nul)
                                                    line
                                                    "")))
            (unless (every (lambda(char)
                             (char= #\space char))
                           line)
              (list line)))
          (uiop:split-string string :separator '(#\newline))))

(defun alignment(list)
  (labels((rec(list &optional acc)
            (if(endp list)
              acc
              (body (car list)(cdr list)acc)))
          (body(first rest acc)
            (if(uiop:string-prefix-p ";;" (string-left-trim " " (car rest)))
              (rec (cons (set-align first (car rest))(cdr rest))
                   (cons first acc))
              (rec rest (cons first acc))))
          (set-align(current comment)
            (with-output-to-string(*standard-output*)
              (loop :for char :across current
                    :while (char= #\space char)
                    :do (write-char char))
              (write-string (string-left-trim " " comment)))))
    (rec (reverse list))))

(declaim (ftype (function (T &optional (or null stream))
                          (values null &optional))
                print-as-code))
(defun print-as-code (exp &optional stream)
  (let*((*print-case*
          :downcase)
        (*print-pprint-dispatch*
          *pprint-dispatch*)
        (*print-pretty*
          t)
        (string
          (prin1-to-string exp))
        (*standard-output*
          (or stream *standard-output*)))
    (loop :for (first . rest) :on (alignment(split-to-lines string))
          :do (if(uiop:string-prefix-p "; " (string-left-trim " " (car rest)))
                (if(uiop:string-prefix-p "; " (string-left-trim " " first))
                  ;; Both are single semicoloned line comment.
                  ;; Integrate it as one for pritty printings.
                  (setf (car rest)
                        (format nil "~A ~A" first (car rest)))
                  ;; Next one is single semicoloned line comment but FIRST.
                  ;; Both should be printed in same line.
                  (progn (format t "~A " first)
                         (rplaca rest (string-left-trim " " (car rest)))))
                (if(uiop:string-prefix-p "; " (string-left-trim " " first))
                  ;; Next is not single semicoloned line comment but FIRST.
                  ;; Comment should be printed.
                  (format t "~<; ~@;~@{~A~^ ~:_~}~:>~:[~;~%~]"
                          (remove "" (uiop:split-string first :separator "; ")
                                  :test #'equal)
                          rest) ; To avoid unneeded newline.
                  ;; Both are not single semicoloned line comment.
                  (if rest
                    ;; To avoid unneeded newline. Especially for conditional.
                    (if(= (1+ (length first))
                          (loop :for num :upfrom 0
                                :for char :across (car rest)
                                :while (char= #\space char)
                                :finally (return num)))
                      (progn (format t "~A " first)
                             (rplaca rest (string-left-trim " " (car rest))))
                      (write-line first))
                    ;; Last line never need newline.
                    (write-string first)))))))

;;;; loop clause
(defvar *print-clause* nil)

;;; CLAUSE
(defstruct (clause (:constructor %make-clause))
  keyword forms)
(defmethod print-object((o clause)stream)
  (if (null *print-clause*)
    (call-next-method)
    (if (clause-keyword o)
      (format stream "~W~@[ ~{~W~^ ~@_~}~]"
              (clause-keyword o)
              (clause-forms o))
      (format stream "~{~W~^ ~_~}" (clause-forms o)))))

;;; OPTIONAL
(defstruct (optional (:include clause)))

;;; ADDITIONAL
(defstruct (additional (:include optional)))
(defmethod print-object((c additional) stream)
  (if(null *print-clause*)
    (call-next-method)
    (let((*indent* (+ 4 *indent*)))
      (format stream "~VI~W~^ ~{~W~^ ~@_~}~5I"
              *indent*
              (clause-keyword c)
              (clause-forms c)))))

;;; ELSE
(defstruct (else (:include optional)))
(defmethod print-object ((c else)stream)
  (if (null *print-clause*)
    (call-next-method)
    (format stream "~2:I~W~:@_~{~W~^~:@_~}~5I"
            (clause-keyword c)
            (clause-forms c))))

;;; VAR
(defstruct (var (:include clause)))
(defmethod print-object((v var) stream)
  (if (null *print-clause*)
    (call-next-method)
    (apply #'format stream "~W~^ ~:I~W~@{~^ ~:_~W~^ ~W~}~5I"
            (clause-keyword v)
            (clause-forms v))))

;;; NESTABLE
(defvar *indent* 5)
(defstruct (nestable (:include clause))
  pred
  else
  end)
(defmethod print-object((c nestable)stream)
  (if (null *print-clause*)
    (call-next-method)
    (progn (format stream "~2:I~W ~W"
                   (clause-keyword c)
                   (nestable-pred c))
           (when (clause-forms c)
             (let((*indent*(+ 2 *indent*)))
               (loop :for form :in (clause-forms c)
                     :do (format stream "~VI~:@_~W"
                                 *indent*
                                 form))))
           (when (nestable-else c)
             (let((current-indent *indent*)
                  (*indent*(+ 2 *indent*)))
               (format stream "~VI~:@_~W"
                       current-indent
                       (nestable-else c))))
           (when(nestable-end c)
             (format stream "~VI~:@_~W"*indent*(nestable-end c))))))

;;; END
(defstruct (end(:include clause)))

;;; OWN-BLOCK
(defstruct (own-block (:include clause)))
(defmethod print-object((c own-block)stream)
  (if (null *print-clause*)
    (call-next-method)
    (format stream "~W~@[ ~:I~{~W~^~:@_~}~]~5I"
            (clause-keyword c)
            (clause-forms c))))

;;; CONSTRUCTOR
(defun make-clause(&key keyword forms)
  (funcall (case (separation-keyword-p keyword)
             ((:for :with :as) #'make-var)
             ((:if :when) #'make-nestable)
             ((:do :doing :finally :initially) #'make-own-block)
             ((:else) #'make-else)
             ((:and) #'make-additional)
             ((:end) #'make-end)
             (otherwise #'%make-clause))
           :keyword keyword
           :forms forms))

(defun print-clause(thing)
  (let((*print-clause* t))
    (pprint-logical-block(nil nil)
      (prin1 thing))))

(defun separation-keyword-p(thing)
  (and (symbolp thing)
       (find thing '(:and
                      :with :for :as
                      :collect :collecting
                      :append :appending
                      :nconc :nconcing
                      :count :counting
                      :sum :summing
                      :maximize :maximizing
                      :minimize :minimizing
                      :if :when :unless :end
                      :while :until :repeat :always :never :thereis
                      :do :doing :initially :finally
                      :return :else
                      )
             :test #'string=)))

(defun parse-loop-body(body)
  (labels((rec(list &optional acc)
            (if(endp list)
              (nreverse acc)
              (multiple-value-bind(obj rest)(pick-clause list)
                (rec rest (cons obj acc))))))
    (rec (make-loop-clauses body))))

(defun make-loop-clauses(body)
  (labels((rec(list &optional temp acc)
            (if (endp list)
              (if temp
                (nreconc acc (list temp))
                (nreverse acc))
              (body (car list)(cdr list)temp acc)))
          (body(first rest temp acc)
            (if(separation-keyword-p first)
              ;; Make new clause.
              (rec rest
                   (make-clause :keyword first)
                   (if temp
                     (cons temp acc)
                     acc))
              (typecase temp
                (null
                  ;; Make new junk clause.
                  (rec rest
                       (make-clause :forms (list first))
                       acc))
                (nestable
                  ;; Set nestable pred, and reset temp NIL.
                  (setf (nestable-pred temp) first)
                  (rec rest nil (cons temp acc)))
                (otherwise
                  ;; Modify temp clause.
                  (rec rest
                       (progn (setf (clause-forms temp)
                                    (nconc (clause-forms temp)
                                           (list first)))
                              temp)
                       acc))))))
    (rec body)))

(declaim (ftype (function (list) (values clause list &optional nil))
                pick-clause))
(defun pick-clause(list)
  (typecase (car list)
    (nestable
      (make-nest (car list)(cadr list)(cddr list)))
    (otherwise
      (values (car list) (cdr list)))))

(declaim (ftype (function (nestable (or clause null) list)
                          (values nestable list &optional nil))
                make-nest))
(defun make-nest (when first rest)
  (typecase first
    (null
      (values when nil))
    (end
      (cond
        ((null(nestable-end when))
         (setf (nestable-end when) first)
         (values when rest))
        (t (values when (cons first rest)))))
    (nestable
      (cond
        ((null (clause-forms when))
         (multiple-value-bind(obj list)(make-nest first (car rest)(cdr rest))
           (setf (clause-forms when)(list obj))
           (make-nest when (car list)(cdr list))))
        ((and (additional-p(car(last(clause-forms when))))
              (null(clause-forms(car(last(clause-forms when))))))
         (multiple-value-bind(obj list)(make-nest first (car rest)(cdr rest))
           (setf (clause-forms(car(last(clause-forms when))))
                 (list obj))
           (make-nest when (car list)(cdr list))))
        ((and (nestable-else when)
              (null (clause-forms(nestable-else when))))
         (multiple-value-bind(obj list)(make-nest first (car rest)(cdr rest))
           (setf (clause-forms(nestable-else when))
                 (list obj))
           (make-nest when (car list)(cdr list))))
        ((and (nestable-else when)
              (additional-p (car(last(clause-forms(nestable-else when)))))
              (null(car(last(clause-forms(nestable-else when))))))
         (multiple-value-bind(obj list)(make-nest first (car rest)(cdr rest))
           (setf (clause-forms(nestable-else when))
                 (append (clause-forms (nestable-else when))
                         (list obj)))
           (make-nest when (car list)(cdr list))))
        (t (values when (cons first rest)))))
    (additional
      (cond
        ((and (nestable-else when)
              (clause-forms (nestable-else when)))
         (setf (clause-forms(nestable-else when))
               (append (clause-forms(nestable-else when))
                       (list first)))
         (make-nest when (car rest)(cdr rest)))
        ((and (nestable-forms when)
              (null(nestable-else when)))
         (setf (clause-forms when)
               (append (clause-forms when)
                       (list first)))
         (make-nest when (car rest)(cdr rest)))
        (t (values when (cons first rest)))))
    (else
      (cond
        ((null (nestable-else when))
         (setf (nestable-else when)
               first)
         (make-nest when (car rest)(cdr rest)))
        (t (values when (cons first rest)))))
    (otherwise
      (cond
        ((null (clause-forms when))
         (setf (clause-forms when) (list first))
         (make-nest when (car rest)(cdr rest)))
        ((and (additional-p (car (last (clause-forms when))))
              (null (clause-forms (car (last (clause-forms when))))))
         (setf (clause-forms (car (last (clause-forms when))))
               (list first))
         (make-nest when (car rest)(cdr rest)))
        ((and (nestable-else when)
              (null (clause-forms (nestable-else when))))
         (setf (clause-forms (nestable-else when))
               (list first))
         (make-nest when (car rest)(cdr rest)))
        ((and (nestable-else when)
              (additional-p (car (last(clause-forms (nestable-else when)))))
              (null(clause-forms(car(last(clause-forms (nestable-else when)))))))
         (setf(clause-forms(car(last(clause-forms (nestable-else when)))))(list first))
         (make-nest when(car rest)(cdr rest)))
        (t (values when (cons first rest)))))))

(defun pprint-extended-loop (stream list)
  (pprint-logical-block(stream nil :prefix "(" :suffix ")")
    (format stream "~W~:[~; ~:I~]" (car list)(cdr list))
    (do*((list (parse-loop-body (cdr list))(cdr list))
         (first (car list)(car list))
         (*print-clause* t))
      ((null list))
      (format stream "~W~:[~;~:@_~]" first (cdr list)))))
