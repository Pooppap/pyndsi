'''
(*)~----------------------------------------------------------------------------------
 Pupil - eye tracking platform
 Copyright (C) 2012-2015  Pupil Labs

 Diunicodeibuted under the terms of the CC BY-NC-SA License.
 License details are in the file LICENSE, diunicodeibuted as part of this software.
----------------------------------------------------------------------------------~(*)
'''

import numpy as np
from os import path
from .frame cimport H264Frame
import logging
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

cdef class H264Writer(object):

    def __cinit__(self, video_loc, width, height, fps=30, *args, **kwargs):
        self.video_loc = video_loc
        # Mp4Writer takes a std:string
        # http://cython.readthedocs.io/en/latest/src/tutorial/strings.html#c-strings
        self.fps = fps
        self.width = width
        self.height = height
        self.timestamps = []
        self.waiting_for_iframe = True
        self.video_stream = new VideoStream(width, height, fps)
        self.proxy = new Mp4Writer(self.video_loc.encode('utf-8'))
        self.proxy.add(self.video_stream)
        self.proxy.start()
        logger.debug("Opened '{}' for writing.".format(self.video_loc))

    def __init__(self, *args, **kwargs):
        pass

    def write_video_frame(self, input_frame):
        if not self.proxy.isRunning():
            logger.error('Mp4Writer not running')
            return
        if not isinstance(input_frame, H264Frame):
            logger.error('Expected H264Frame but got {}'.format(type(input_frame)))
            return
        if not self.width == input_frame.width:
            logger.error('Expected width {} but got {}'.format(self.width, input_frame.width))
        if not self.height == input_frame.height:
            logger.error('Expected height {} but got {}'.format(self.height, input_frame.height))

        if self.waiting_for_iframe:
            if input_frame.is_iframe:
                self.waiting_for_iframe = False
            else:
                logger.warning('No I-frame found yet -- dropping frame.')
                return

        cdef unsigned char[:] buffer_ = input_frame.h264_buffer
        cdef long long pts = <long long>(input_frame.timestamp * 1000000)
        self.proxy.set_input_buffer(0, &buffer_[0], len(buffer_), pts)
        self.timestamps.append(input_frame.timestamp)

    def close(self):
        if self.proxy != NULL:
            self.proxy.release()
            self.proxy = NULL
        self.write_timestamps()

    def release(self):
        self.close()

    def write_timestamps(self):
        directory, video_file = path.split(self.video_loc)
        name, ext = path.splitext(video_file)
        ts_file = '{}_timestamps.npy'.format(name)
        ts_loc = path.join(directory, ts_file)
        ts = np.array(self.timestamps)
        np.save(ts_loc, ts)
