classdef SpikeReader < handle
    % SR = SpikeReader(spikeFile) creates a new instance of class SpikeReader.
    %
    % SpikeReader can be used to read spike files generated by the SpikeMonitor
    % utility in CARLsim.
    %
    %
    % Version 10/2/2014
    % Author: Michael Beyeler <mbeyeler@uci.edu>
    
    %% PROPERTIES
    % public
    properties (SetAccess = private)
        fileStr;            % path to spike file
    end

    % private
    properties (Hidden, Access = private)
        fileId;             % file ID of spike file
        fileSignature;      % int signature of all spike files
        fileVersionMajor;   % required major version number
        fileVersionMinor;   % required minimum minor version number
        fileSizeByteHeader; % byte size of header section

        grid3D;
        numFrames;

        errorMode;          % program mode for error handling
        errorFlag;          % error flag (true if error occured)
        errorMsg;           % error message

        supportedErrorModes;% supported error modes
    end
    
    
    %% PUBLIC METHODS
    methods
        function obj = SpikeReader(spikeFile, errorMode)
            % SR = SpikeReader(spikeFile) creates a new instance of class
            % SpikeReader, which can be used to read spike files generated by
            % the SpikeMonitor utility in CARLsim.
            %
            % SPIKEFILE   - Path to spike file (expects data to be in Adress-
            %               Event-Representation AER: spike time (ms) followed
            %               by neuron ID (both int32)), like the ones created
            %               by the CARLsim SpikeMonitor utility.
            % ERRORMODE   - Error Mode in which to run SpikeReader. The
            %               following modes are supported:
            %                 - 'standard' Errors will be fatal (returned via
            %                              Matlab function error())
            %                 - 'warning'  Errors will be warnings (returned via
            %                              Matlab function warning())
            %                 - 'silent'   No exceptions will be thrown, but
            %                              object will populate the properties
            %                              errorFlag and errorMsg.
            %               Default: 'standard'.
            obj.fileStr = spikeFile;
            obj.unsetError()
            obj.loadDefaultParams();

            if nargin<2
                obj.errorMode = 'standard';
            else
                if ~obj.isErrorModeSupported(errorMode)
                    obj.throwError(['errorMode "' errorMode '" is currently' ...
                        ' not supported. Choose from the following: ' ...
                        strjoin(obj.supportedErrorModes, ', ') '.'], ...
                        'standard')
                    return
                end
                obj.errorMode = errorMode;
            end
            if nargin<1
                obj.throwError('Path to spike file needed.');
                return
            end
            
            % move unsafe code out of constructor
            obj.openFile()
        end
        
        function delete(obj)
            % destructor, implicitly called to fclose file
            if obj.fileId ~= -1
                fclose(obj.fileId);
            end
        end

        function [errFlag,errMsg] = getError(obj)
            % [errFlag,errMsg] = getError() returns the current error status.
            % If an error has occurred, errFlag will be true, and the message
            % can be found in errMsg.
            errFlag = obj.errorFlag;
            errMsg = obj.errorMsg;
        end

        function dims = getGrid3D(obj)
            dims = obj.grid3D;
        end

        function spk = readSpikes(obj, frameDur)
            % spk = readSpikes(frameDur) reads the spike file and arranges
            % spike times into bins of frameDur millisecond length.
            %
            % Returns a 2-D matrix (spike times x neuron IDs), 1-indexed.
            %
            % FRAMEDUR    - Size of binning window for spike times (ms).
            %               Set frameDur to -1 in order to get the spikes in
            %               AER format [times;nIDs].
            %               Default: 1000.
            if nargin<1,frameDur=1000;end

            obj.unsetError()
            
            % rewind file pointer, skip header
            fseek(obj.fileId, obj.fileSizeByteHeader, 'bof');
            nrRead=1e6;
            d=zeros(0,nrRead);
            spk=[];
            
            while size(d,2)==nrRead
                % D is a 2xNRREAD matrix.  Row 1 contains the times that
                % the neuron spiked. Row 2 contains the neuron id that
                % spiked at this corresponding time.
                d = fread(obj.fileId, [2 nrRead], 'int32');
                
                if ~isempty(d)
                    if frameDur<0
                        % Return data in AER format, i.e.: [time;nID]
                        % Note: Using SPARSE on large matrices that mostly
                        % contain 0 is inefficient (-> "big sparse matrix")
                        spk = [spk, d];
                    else
                        % Resulting matrix s will have rows corresponding
                        % to time values with a minimum value of 1 and
                        % columns organized by neuron ids that are indexed
                        % starting with 1.  FRAMEDUR effectively bins the
                        % data. FRAMEDUR=1 bins at 1 ms, FRAMEDUR=1000 bins
                        % at 1000 ms, etc.
                        
                        % Initialize the entire S matrix to 0 with the
                        % correct dimensions.
                        maxR = floor(d(1,end)/frameDur)+1;
                        maxC = max(d(2,:))+1;
                        if size(spk,1)~=maxR || size(spk,2)~=maxC
                            spk(maxR, maxC)=0;
                        end
                        
                        % Use sparse matrix to create a matrix S with
                        % correct dimensions. All firing events for each
                        % neuron id and time bin are summed automatically
                        % with ACCUMARRAY.  Finally the matrix is resized
                        % to include all the zero entries with the correct
                        % matrix dimensions. ACCUMARRAY is supposed to be
                        % faster than full(sparse(...)). Make sure the
                        % first two arguments are column vectors.
                        subs = [floor(d(1,:)/frameDur)'+1,d(2,:)'+1];
                        spk = spk + accumarray(subs, 1, size(spk));
                    end
                end
            end

            % grow to right size
            if size(spk,2) ~= prod(obj.grid3D)
                spk(end,prod(obj.grid3D))=0;
            end
            obj.numFrames = size(spk,1);
        end
    end
    
    %% PRIVATE METHODS
    methods (Hidden, Access = private)
        function isSupported = isErrorModeSupported(obj, errMode)
            % determines whether an error mode is currently supported
            isSupported = sum(ismember(obj.supportedErrorModes,errMode))>0;
        end

        function loadDefaultParams(obj)
            obj.fileId = -1;
            obj.fileSignature = 206661989;
            obj.fileVersionMajor = 0;
            obj.fileVersionMinor = 2;
            obj.fileSizeByteHeader = 5*4;

            obj.grid3D = -1;
            obj.numFrames = -1;
            
            obj.supportedErrorModes = {'standard', 'warning', 'silent'};
        end
        
        function openFile(obj)
            obj.unsetError()

            % try to open spike file
            obj.fileId = fopen(obj.fileStr,'r');
            if obj.fileId==-1
                obj.throwError(['Could not open file "' obj.fileStr ...
                    '" with read permission'])
                return
            end
            
            % read signature
            sign = fread(obj.fileId, 1, 'int32');
            if sign~=obj.fileSignature
                obj.throwError('Unknown file type');
                return
            end
            
            % read version number
            % read version number
            version = fread(obj.fileId, 1, 'float32');
            if floor(version) ~= obj.fileVersionMajor
                % check major number: must match
                obj.throwError(['File must be of version ' ...
                    num2str(obj.fileVersionMajor) '.x (Version ' ...
                    num2str(version) ' found'])
                return
            end
            if floor((version-obj.fileVersionMajor)*10.01)<obj.fileVersionMinor
                % check minor number: extract first digit after decimal point
                % multiply 10.01 instead of 10 to avoid float rounding errors
                obj.throwError(['File version must be >= ' ...
                    num2str(obj.fileVersionMajor) '.' ...
                    num2str(obj.fileVersionMinor) ' (Version ' ...
                    num2str(version) ' found)'])
                return
            end

            % read Grid3D
            obj.grid3D = fread(obj.fileId, 3, 'int32');
            if prod(obj.grid3D)<=0
                obj.throwError(['Could not find valid Grid3D dimensions.'])
                return
            end
        end

        function throwError(obj, errorMsg, errorMode)
            % THROWERROR(errorMsg, errorMode) throws an error with a specific
            % severity (errorMode). In all cases, obj.errorFlag is set to true
            % and the error message is stored in obj.errorMsg. Depending on
            % errorMode, an error is either thrown as fatal, thrown as warning,
            % or not thrown at all.
            % If errorMode is not given, obj.errorMode is used.
            if nargin<3,errorMode=obj.errorMode;end
            obj.errorFlag = true;
            obj.errorMsg = errorMsg;
            if strcmpi(errorMode,'standard')
                error(errorMsg)
            elseif strcmpi(errorMode,'warning')
                warning(errorMsg)
            end
        end

        function unsetError(obj)
            % unsets error message and flag
            obj.errorFlag = false;
            obj.errorMsg = '';
        end
    end
end